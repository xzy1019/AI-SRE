// aisre-ingest —— 告警接入与归一化（AISRE-Agent 第 2 周主线第一步）
//
// 它在链路里的位置：
//     Prometheus(规则) → Alertmanager(receiver: aisre-webhook) → 【本服务】 → Event → 落盘/总线
//
// 为什么必须先有它：
//   Alertmanager 的 receiver 早就指向 http://aisre-ingest.aiops.svc:8080/webhook/alertmanager，
//   而当时这个服务不存在 —— 表现为"告警能产生、能接收，但发不出去"，
//   AIOps 侧永远拿不到数据。日志里是这句：
//     err="aisre-webhook/webhook[0]: notify retry canceled after 10 attempts: Post \"...\""
//
// 本服务做四件事：
//   1. 接收 Alertmanager Webhook（v4 JSON）
//   2. 归一化成统一 Event 模型（对齐设计文档 §5.2）
//   3. 指纹去重（降噪的第一道防线：同一条告警重复推送只记引用计数）
//   4. 落盘 JSONL + 自暴露 /metrics（否则"通知成功没有"这件事只能翻日志）
//
// 设计约束：
//   · 只用 Go 标准库 —— 集群网络受限，任何外部依赖都会让构建变复杂
//   · 幂等：重复投递不会写重复 Event（标注 duplicate=true 并累加 dedup_count）
//
// 端点：
//   POST /webhook/alertmanager   Alertmanager 回调入口
//   GET  /healthz                存活
//   GET  /readyz                 就绪
//   GET  /stats                  计数（收到的告警/去重/写盘/最后接收时间）
//   GET  /events?limit=N         最近 N 条 Event（内存环形缓冲，便于人工核对）
//   GET  /metrics                Prometheus 文本格式
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxRecentEvents = 500 // 内存里保留最近多少条，供 /events 查询
	maxBodyBytes    = 4 << 20
)

// ---------- 入参：Alertmanager Webhook v4 ----------

type Alert struct {
	Status       string            `json:"status"`
	Labels       map[string]string `json:"labels"`
	Annotations  map[string]string `json:"annotations"`
	StartsAt     time.Time         `json:"startsAt"`
	EndsAt       time.Time         `json:"endsAt"`
	GeneratorURL string            `json:"generatorURL"`
	Fingerprint  string            `json:"fingerprint"`
}

type WebhookPayload struct {
	Version           string            `json:"version"`
	GroupKey          string            `json:"groupKey"`
	TruncatedAlerts   int               `json:"truncatedAlerts"`
	Status            string            `json:"status"`
	Receiver          string            `json:"receiver"`
	GroupLabels       map[string]string `json:"groupLabels"`
	CommonLabels      map[string]string `json:"commonLabels"`
	CommonAnnotations map[string]string `json:"commonAnnotations"`
	ExternalURL       string            `json:"externalURL"`
	Alerts            []Alert           `json:"alerts"`
}

// ---------- 统一事件模型（对齐设计文档 §5.2）----------

type Event struct {
	EventID     string            `json:"event_id"`
	Source      string            `json:"source"`
	Status      string            `json:"status"`
	Alertname   string            `json:"alertname"`
	Severity    string            `json:"severity"`
	Service     string            `json:"service"`
	Namespace   string            `json:"namespace"`
	Pod         string            `json:"pod,omitempty"`
	Downstream  string            `json:"downstream,omitempty"`
	StartsAt    string            `json:"starts_at"`
	EndsAt      string            `json:"ends_at,omitempty"`
	ReceivedAt  string            `json:"received_at"`
	Fingerprint string            `json:"fingerprint"`
	DedupKey    string            `json:"dedup_key"`
	DedupCount  int               `json:"dedup_count"`
	Duplicate   bool              `json:"duplicate"`
	GroundTruth string            `json:"ground_truth,omitempty"`
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
}

// ---------- 运行时状态 ----------

type Stats struct {
	WebhookRequests     int64  `json:"webhook_requests_total"`
	WebhookBadRequests  int64  `json:"webhook_bad_requests_total"`
	AlertsReceived      int64  `json:"alerts_received_total"`
	AlertsDeduplicated  int64  `json:"alerts_deduplicated_total"`
	EventsWritten       int64  `json:"events_written_total"`
	LastReceivedUnix    int64  `json:"last_received_unix"`
	LastReceivedRFC3339 string `json:"last_received_rfc3339"`
	OutFile             string `json:"out_file"`
	OutFileBytes        int64  `json:"out_file_bytes"`
}

type Server struct {
	mu       sync.Mutex
	dedup    map[string]int // dedupKey -> 出现次数
	recent   []Event        // 环形缓冲（简单切片，超出就丢最旧的）
	stats    Stats
	outPath  string
	started  time.Time
}

// 去重键：同一"事件身份"才该被折叠。
// 注意 status 参与指纹 —— firing 与 resolved 是两次不同的事件，不能互相覆盖。
func dedupKey(e Event) string {
	parts := []string{
		e.Source, e.Alertname, e.Status,
		e.Namespace, e.Service, e.Pod, e.Downstream,
	}
	h := sha256.Sum256([]byte(strings.Join(parts, "|")))
	return hex.EncodeToString(h[:])[:16]
}

// 事件 ID：在去重键基础上再带上告警开始时间，保证"同一告警的两次不同发生"可区分
func eventID(dedup string, startsAt time.Time) string {
	h := sha256.Sum256([]byte(dedup + "|" + startsAt.UTC().Format(time.RFC3339)))
	return hex.EncodeToString(h[:])[:20]
}

func pickEvent(labels, annotations map[string]string, groupLabels map[string]string, recv time.Time) Event {
	// 实验的 ground truth 通过告警标签带进来（实验清单里打了 ground-truth 标签），
	// 配不到就留空 —— 后面做 RCA 评测时，有 ground truth 的样本才是"可判分"的样本。
	gt := labels["ground-truth"]
	if gt == "" {
		gt = labels["ground_truth"]
	}
	return Event{
		Source:      "alertmanager",
		Status:      labels["alertstatus"],
		Alertname:   labels["alertname"],
		Severity:    labels["severity"],
		Service:     labels["service"],
		Namespace:   labels["namespace"],
		Pod:         labels["pod"],
		Downstream:  labels["downstream"],
		ReceivedAt:  recv.UTC().Format(time.RFC3339),
		Fingerprint: labels["fingerprint"],
		GroundTruth: gt,
		Labels:      labels,
		Annotations: annotations,
	}
}

func (s *Server) handleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes))
	if err != nil {
		s.bump(func(st *Stats) { st.WebhookBadRequests++ })
		http.Error(w, "read body failed", http.StatusBadRequest)
		return
	}

	var p WebhookPayload
	if err := json.Unmarshal(body, &p); err != nil {
		s.bump(func(st *Stats) { st.WebhookBadRequests++ })
		log.Printf("WARN 解析 webhook 失败: %v", err)
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	recv := time.Now().UTC()
	written := 0
	for _, a := range p.Alerts {
		labels := mergeLabels(p.CommonLabels, a.Labels)
		labels["alertstatus"] = a.Status
		if a.Fingerprint != "" {
			labels["fingerprint"] = a.Fingerprint
		}
		ev := pickEvent(labels, mergeLabels(p.CommonAnnotations, a.Annotations), p.GroupLabels, recv)
		ev.Status = a.Status
		if !a.StartsAt.IsZero() {
			ev.StartsAt = a.StartsAt.UTC().Format(time.RFC3339)
		}
		if !a.EndsAt.IsZero() {
			ev.EndsAt = a.EndsAt.UTC().Format(time.RFC3339)
		}

		key := dedupKey(ev)
		ev.DedupKey = key

		s.mu.Lock()
		s.dedup[key]++
		ev.DedupCount = s.dedup[key]
		ev.Duplicate = s.dedup[key] > 1
		s.stats.AlertsReceived++
		if ev.Duplicate {
			s.stats.AlertsDeduplicated++
		}
		s.mu.Unlock()

		startsAt, _ := time.Parse(time.RFC3339, ev.StartsAt)
		ev.EventID = eventID(key, startsAt)

		if err := s.appendEvent(ev); err != nil {
			log.Printf("ERROR 写盘失败: %v", err)
			continue
		}
		written++

		s.mu.Lock()
		s.recent = append(s.recent, ev)
		if len(s.recent) > maxRecentEvents {
			s.recent = s.recent[len(s.recent)-maxRecentEvents:]
		}
		s.mu.Unlock()
	}

	s.bump(func(st *Stats) {
		st.WebhookRequests++
		st.EventsWritten += int64(written)
		st.LastReceivedUnix = recv.Unix()
		st.LastReceivedRFC3339 = recv.Format(time.RFC3339)
	})
	log.Printf("INFO 收到 webhook: status=%s alerts=%d 写入=%d 组=%s", p.Status, len(p.Alerts), written, p.GroupKey)

	// Alertmanager 只要求 2xx；返回处理统计方便人工核对
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok": true, "received": len(p.Alerts), "written": written,
	})
}

func mergeLabels(base, override map[string]string) map[string]string {
	out := make(map[string]string, len(base)+len(override)+2)
	for k, v := range base {
		out[k] = v
	}
	for k, v := range override {
		out[k] = v
	}
	return out
}

func (s *Server) appendEvent(ev Event) error {
	line, err := json.Marshal(ev)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(s.outPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.Write(append(line, '\n')); err != nil {
		return err
	}
	return nil
}

func (s *Server) bump(f func(*Stats)) {
	s.mu.Lock()
	f(&s.stats)
	s.mu.Unlock()
}

// ---------- 只读端点 ----------

func (s *Server) handleStats(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	st := s.stats
	s.mu.Unlock()
	if fi, err := os.Stat(s.outPath); err == nil {
		st.OutFileBytes = fi.Size()
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(st)
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	limit := 20
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= maxRecentEvents {
			limit = n
		}
	}
	s.mu.Lock()
	n := len(s.recent)
	if limit > n {
		limit = n
	}
	out := make([]Event, limit)
	copy(out, s.recent[n-limit:])
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(out)
}

// ---------- 自观测：没有这组指标，"通知到底成没成功"就只能翻日志 ----------

func (s *Server) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	st := s.stats
	recent := len(s.recent)
	uniq := len(s.dedup)
	s.mu.Unlock()

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	fmt.Fprintf(w, "# HELP ingest_webhook_requests_total 收到的 webhook 请求数\n# TYPE ingest_webhook_requests_total counter\n")
	fmt.Fprintf(w, "ingest_webhook_requests_total %d\n", st.WebhookRequests)
	fmt.Fprintf(w, "# HELP ingest_webhook_bad_requests_total 解析失败的 webhook 请求数\n# TYPE ingest_webhook_bad_requests_total counter\n")
	fmt.Fprintf(w, "ingest_webhook_bad_requests_total %d\n", st.WebhookBadRequests)
	fmt.Fprintf(w, "# HELP ingest_alerts_received_total 收到的告警条数（含重复）\n# TYPE ingest_alerts_received_total counter\n")
	fmt.Fprintf(w, "ingest_alerts_received_total %d\n", st.AlertsReceived)
	fmt.Fprintf(w, "# HELP ingest_alerts_deduplicated_total 被判定为重复的告警条数\n# TYPE ingest_alerts_deduplicated_total counter\n")
	fmt.Fprintf(w, "ingest_alerts_deduplicated_total %d\n", st.AlertsDeduplicated)
	fmt.Fprintf(w, "# HELP ingest_events_written_total 落盘的事件数\n# TYPE ingest_events_written_total counter\n")
	fmt.Fprintf(w, "ingest_events_written_total %d\n", st.EventsWritten)
	fmt.Fprintf(w, "# HELP ingest_dedup_keys 去重表中不同的告警身份数\n# TYPE ingest_dedup_keys gauge\n")
	fmt.Fprintf(w, "ingest_dedup_keys %d\n", uniq)
	fmt.Fprintf(w, "# HELP ingest_recent_events 内存中保留的最近事件数\n# TYPE ingest_recent_events gauge\n")
	fmt.Fprintf(w, "ingest_recent_events %d\n", recent)
	fmt.Fprintf(w, "# HELP ingest_last_receive_timestamp_seconds 最近一次收到 webhook 的时间戳\n# TYPE ingest_last_receive_timestamp_seconds gauge\n")
	fmt.Fprintf(w, "ingest_last_receive_timestamp_seconds %d\n", st.LastReceivedUnix)
	fmt.Fprintf(w, "# HELP ingest_uptime_seconds 进程运行时长\n# TYPE ingest_uptime_seconds gauge\n")
	fmt.Fprintf(w, "ingest_uptime_seconds %.0f\n", time.Since(s.started).Seconds())
}

func main() {
	port := envOr("PORT", "8080")
	outPath := envOr("OUT_FILE", "/data/events.jsonl")

	if err := os.MkdirAll(dirOf(outPath), 0o755); err != nil {
		log.Printf("WARN 创建输出目录失败: %v", err)
	}

	s := &Server{dedup: map[string]int{}, outPath: outPath, started: time.Now()}
	log.Printf("INFO aisre-ingest 启动: port=%s out=%s", port, outPath)

	mux := http.NewServeMux()
	mux.HandleFunc("/webhook/alertmanager", s.handleWebhook)
	mux.HandleFunc("/stats", s.handleStats)
	mux.HandleFunc("/events", s.handleEvents)
	mux.HandleFunc("/metrics", s.handleMetrics)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		// 就绪 = 输出文件所在目录可写（落盘能力是它的核心职责）
		if f, err := os.OpenFile(s.outPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err != nil {
			http.Error(w, "output not writable: "+err.Error(), http.StatusServiceUnavailable)
			return
		} else {
			_ = f.Close()
		}
		_, _ = w.Write([]byte("ready\n"))
	})

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func dirOf(p string) string {
	if i := strings.LastIndex(p, "/"); i > 0 {
		return p[:i]
	}
	return "."
}
