# SagePod dependency
SERVICE             ?= sagepod

# Inside-container execution
CONTAINER_WORKDIR   ?= /sage
SAGE_BIN            = ./sage

# SagePod notebook mount locations
NOTEBOOKS_CONT      ?= /home/sage/notebooks
NOTEBOOKS_HOST      ?= $(HOME)/Jupyter

# Worker loop
SLEEP_EMPTY         ?= 2

# Concurrency / partitioning
STRIDE              ?= 8
WORKERS             ?= $(STRIDE)

