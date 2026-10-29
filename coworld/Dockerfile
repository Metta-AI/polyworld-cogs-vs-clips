FROM ubuntu:24.04 AS compiler
RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ git curl ca-certificates xz-utils python3 libopenblas-dev && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://github.com/nim-lang/nightlies/releases/download/2026-04-24-version-2-2-bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef/nim-2.2.10-linux_x64.tar.xz | tar xJ -C /opt
ENV PATH=/opt/nim-2.2.10/bin:$PATH
WORKDIR /src/cvc
COPY dependencies.lock dependencies.lock
COPY tools/setup_dependencies.py tools/setup_dependencies.py
RUN python3 tools/setup_dependencies.py
ENV POLYWORLD_DEPS=/src/cvc/.deps
COPY config.nims config.nims
COPY src src
COPY data/maps data/maps
COPY players players
RUN nim c -d:release -d:headless -d:coworld -d:tensorBlas --nimcache:/tmp/nimcache -o:/out/game src/cvc.nim
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends libcurl4t64 libopenblas0-pthread ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=compiler /out/game /usr/local/bin/cvc
ENV OPENBLAS_NUM_THREADS=1
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/cvc"]
