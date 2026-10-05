#!/usr/bin/env bash
set -euo pipefail

kind delete cluster --name sparta-prd
kind delete cluster --name sparta-dr
