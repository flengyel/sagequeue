# podman-compose wiring
COMPOSE_FILE        ?= podman-compose.yml
SERVICE             ?= sagemath

# Inside-container execution
CONTAINER_WORKDIR   ?= /sage
SAGE_BIN            = ./sage

# Notebook bind mount locations (matches podman-compose.yml)
NOTEBOOKS_CONT      ?= /home/sage/notebooks
NOTEBOOKS_HOST      ?= $(HOME)/Jupyter

# Worker loop
SLEEP_EMPTY         ?= 2

# Concurrency / partitioning
STRIDE              ?= 8
WORKERS             ?= $(STRIDE)

