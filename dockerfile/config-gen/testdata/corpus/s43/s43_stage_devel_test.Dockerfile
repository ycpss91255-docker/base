# tool-pin: ignore -- fixture bytes for the stage parser, never built (base#2093)
FROM ubuntu:24.04 AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM runtime AS runtime-test
