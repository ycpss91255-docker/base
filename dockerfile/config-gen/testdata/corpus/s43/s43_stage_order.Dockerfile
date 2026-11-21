# tool-pin: ignore -- fixture bytes for the stage parser, never built (base#2093)
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS gamma
FROM devel AS alpha
FROM devel AS beta
