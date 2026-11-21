FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS test
