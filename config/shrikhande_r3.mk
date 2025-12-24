include config/common.mk

JOBSET      := shri_r3
GRAPH       := shrikhande
RANK        := 3
STRIDE      := 8
WORKERS     := 8

LOG_PREFIX  := shri_r3

SCRIPT_BASENAME := rank_boundary_sat_v18.sage
SCRIPT_CONT     := $(NOTEBOOKS_CONT)/$(SCRIPT_BASENAME)

STOP_BASENAME   := shri_r3_stop.txt
STOP_FILE_CONT  := $(NOTEBOOKS_CONT)/$(STOP_BASENAME)
STOP_FILE_HOST  := $(NOTEBOOKS_HOST)/$(STOP_BASENAME)

# Exactly your flags, excluding --stride and --offset
SAGE_BASE_ARGS := --graph $(GRAPH) --rank $(RANK) --solver sat --sat_backend cryptominisat \
                  --scan_all_J --want_solution \
                  --resume --stop_file $(STOP_FILE_CONT) \
                  --progress_every 1

