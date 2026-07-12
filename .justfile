#!/usr/bin/env -S just --justfile

set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]

[group("Repository")]
mod repo ".just/repository.just"

[group("Talos")]
mod talos "talos"

[group("Bootstrap")]
mod bootstrap ".just/bootstrap.just"

[group("Kubernetes")]
mod kube "kubernetes"
