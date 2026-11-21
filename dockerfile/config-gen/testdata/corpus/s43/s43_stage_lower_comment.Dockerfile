FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel as lower_as_keyword
# FROM devel AS commented_out
FROM devel AS prod
