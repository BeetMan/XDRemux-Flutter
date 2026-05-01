.PHONY: status dev test lint smoke verify help

PYTHON ?= $(shell if [ -x .venv/bin/python ]; then echo .venv/bin/python; else echo python3; fi)

all: help

help:
	@echo "========================================================"
	@echo " ProXDR Harness Engineering - Unified Entry "
	@echo "========================================================"
	@echo "make status  - 输出工程状态与关键 gate"
	@echo "make dev     - 动态探针开发入口与依赖检查"
	@echo "make lint    - 语法/结构/workflow 约束检查"
	@echo "make test    - repo-level + oracle-dump 回归测试"
	@echo "make smoke   - 最小链路冒烟检查"
	@echo "make verify  - lint + test + smoke + 架构边界收口"
	@echo "========================================================"

status:
	@$(PYTHON) harness/harness_status.py

dev:
	@$(PYTHON) scripts/dev_entry.py

lint:
	@$(PYTHON) scripts/lint_repo.py

test:
	@$(PYTHON) evals/test_eval.py

smoke:
	@$(PYTHON) scripts/smoke_test.py

verify: lint test smoke
	@$(PYTHON) scripts/check_architecture.py
	@echo "[OK] verify 通过"
