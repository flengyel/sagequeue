# Containerfile for a SageMath image with pycryptosat preinstalled.
#
# Goal: make Sage's `cryptominisat` SAT backend usable without reinstalling after reboots
# or after recreating the container.
#
# Build:
#   podman build -f Containerfile --build-arg SAGE_TAG=10.7 -t localhost/sagequeue-sagemath:10.7-pycryptosat .
#
# Then update podman-compose.yml to use:
#   image: localhost/sagequeue-sagemath:${SAGE_TAG:-10.7}-pycryptosat

ARG SAGE_TAG=10.7
FROM ghcr.io/sagemath/sage/sage-debian-bullseye-standard-with-targets-optional:${SAGE_TAG}

# Install toolchain needed to build pycryptosat from source.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /home/sage && chown -R 1000:1000 /home/sage
ENV HOME=/home/sage
ENV DOT_SAGE=/home/sage/.sage


# Build/install pycryptosat inside Sage's Python environment.
# Run as the normal (uid 1000) user so the installation lands in the expected Sage prefix.
USER 1000:1000
WORKDIR /sage

RUN ./sage -pip uninstall -y pycryptosat || true
RUN ./sage -pip install --no-binary=pycryptosat pycryptosat==5.11.21

# Fail-fast verification at build time.
RUN ./sage -python -c "from pycryptosat import Solver; s=Solver(); s.add_clause([1]); print(s.solve())"
