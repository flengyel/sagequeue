include config/common.mk

JOBSET      := template
STRIDE      := 8
WORKERS     := 8

LOG_PREFIX  := $(JOBSET)

SCRIPT_BASENAME := template.sage
SCRIPT_CONT     := $(NOTEBOOKS_CONT)/$(SCRIPT_BASENAME)

STOP_BASENAME   := $(JOBSET)_stop.txt
STOP_FILE_CONT  := $(NOTEBOOKS_CONT)/$(STOP_BASENAME)
STOP_FILE_HOST  := $(NOTEBOOKS_HOST)/$(STOP_BASENAME)

# Template workload parameters (explicit; domain-free).
TOTAL_CASES := 455

# Worker injects --stride/--offset. Do not include them here.
SAGE_BASE_ARGS := --resume --stop_file $(STOP_FILE_CONT) --progress_every 1 \
                  --work_secs 0.05 --total_cases $(TOTAL_CASES) --state_prefix $(JOBSET)

