# Containerfile for a SageMath image with pycryptosat preinstalled.
#
# This bakes pycryptosat into the image so Sage's `cryptominisat` SAT backend works
# even after the container is removed/recreated (e.g. `podman-compose down`).
#
# Build example:
#   podman build -f Containerfile --build-arg SAGE_TAG=10.7 \
#     -t localhost/sagequeue-sagemath:10.7-pycryptosat .
#
# Then `podman-compose.yml` should reference:
#   image: localhost/sagequeue-sagemath:${SAGE_TAG:-10.7}-pycryptosat

ARG SAGE_TAG=10.7
FROM ghcr.io/sagemath/sage/sage-debian-bullseye-standard-with-targets-optional:${SAGE_TAG}

# Build dependencies for a source install of pycryptosat.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Sage's launcher expects HOME to be set; set it explicitly for build-time RUN steps.
# Also ensure the directory exists and is owned by the Sage user (uid 1000).
RUN mkdir -p /home/sage && chown -R 1000:1000 /home/sage
ENV HOME=/home/sage
ENV DOT_SAGE=/home/sage/.sage

# Install pycryptosat inside Sage's Python environment.
USER 1000:1000
WORKDIR /sage

RUN ./sage -pip uninstall -y pycryptosat || true
RUN ./sage -pip install --no-binary=pycryptosat pycryptosat==5.11.21

# Fail-fast verification at build time.
RUN ./sage -python -c "from pycryptosat import Solver; s=Solver(); s.add_clause([1]); print(s.solve())"
