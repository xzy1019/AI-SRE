#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
31-sync-prometheus-config.py —— 把可观测性"人读源文件"确定性渲染进部署清单

问题背景（为什么需要这个脚本）：
    manifests/observability/ 下有两份东西描述同一件事——
      · _prometheus.yml / _prometheus-rules.yml   （下划线开头：人读源文件，不被 apply）
      · 03-prometheus.yaml 里的 ConfigMap          （真正被 kubectl apply 的内容）
    这两个是**手工同步**关系。改了一边忘了另一边，就会出现"规则写在人读文件里、
    实际跑的还是老规则"这类沉默故障 —— 排查时看文件全对，运行时状态全错（与 P01 同类）。

本脚本把源文件按固定缩进渲染进 03-prometheus.yaml 的 ConfigMap，
使 "_prometheus*.yml 是唯一事实来源"，并支持 --check 做一致性校验。

用法:
    python3 31-sync-prometheus-config.py          # 渲染（写回 03-prometheus.yaml）
    python3 31-sync-prometheus-config.py --check  # 只校验是否已同步（CI / 提交前用）
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OBS = os.path.join(ROOT, "manifests", "observability")
TARGET = os.path.join(OBS, "03-prometheus.yaml")
SRC_PROM = os.path.join(OBS, "_prometheus.yml")
SRC_RULES = os.path.join(OBS, "_prometheus-rules.yml")

INDENT = "    "          # ConfigMap 里的内容统一缩进 4 空格
KEY_PROM = "  prometheus.yml: |"
KEY_RULES = "  rules.yml: |"


def read(p):
    return io.open(p, encoding="utf-8").read().replace("\r\n", "\n").rstrip("\n")


def render():
    lines = read(TARGET).split("\n")
    i_prom = i_rules = None
    for i, l in enumerate(lines):
        if l.rstrip() == KEY_PROM:
            i_prom = i
        elif l.rstrip() == KEY_RULES:
            i_rules = i
    if i_prom is None or i_rules is None or i_rules <= i_prom:
        raise SystemExit("渲染失败：在 %s 里找不到 ConfigMap 的 %s / %s" % (TARGET, KEY_PROM, KEY_RULES))
    i_tail = None
    for i in range(i_rules + 1, len(lines)):
        if lines[i].rstrip() == "---":
            i_tail = i
            break
    if i_tail is None:
        raise SystemExit("渲染失败：rules.yml 之后找不到 '---' 分隔符")

    def ind(text):
        return [(INDENT + l) if l.strip() else "" for l in text.split("\n")]

    out = []
    out += lines[: i_prom + 1]
    out += ind(read(SRC_PROM))
    out += [""]
    out += [KEY_RULES]
    out += ind(read(SRC_RULES))
    out += [""]
    out += lines[i_tail:]
    return "\n".join(out) + "\n"


def main():
    check = "--check" in sys.argv[1:]
    new = render()
    old = io.open(TARGET, encoding="utf-8", newline="").read().replace("\r\n", "\n")
    if old == new:
        print("✔ 已同步：03-prometheus.yaml 与 _prometheus*.yml 一致")
        return 0
    if check:
        print("✘ 未同步：03-prometheus.yaml 与 _prometheus*.yml 不一致")
        print("  修复：python3 scripts/31-sync-prometheus-config.py")
        return 1
    io.open(TARGET, "w", encoding="utf-8", newline="").write(new)
    print("✔ 已渲染：_prometheus.yml + _prometheus-rules.yml → 03-prometheus.yaml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
