#!/usr/bin/env bash

# BAISH agent module — sourcing facade.
# Each concern lives in its own sub-module under lib/agent/.
_agent_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$_agent_dir/agent/display.sh"
source "$_agent_dir/agent/summary.sh"
source "$_agent_dir/agent/phase.sh"
source "$_agent_dir/agent/streaming.sh"
source "$_agent_dir/agent/messages.sh"
source "$_agent_dir/agent/connection.sh"
source "$_agent_dir/agent/run-loop.sh"

unset _agent_dir
