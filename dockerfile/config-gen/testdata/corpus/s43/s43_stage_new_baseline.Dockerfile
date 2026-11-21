FROM ubuntu:24.04 AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM runtime AS runtime-test
