#!/bin/bash

set -e

die() {
  local _ret="${2:-1}"
  test "${_PRINT_HELP:-no}" = yes && print_help >&2
  echo "$1" >&2
  exit "${_ret}"
}

begins_with_short_option() {
  local first_option all_short_options='h'
  first_option="${1:0:1}"
  test "$all_short_options" = "${all_short_options/$first_option/}" && return 1 || return 0
}

# THE DEFAULTS INITIALIZATION - POSITIONALS
_positionals=()
# THE DEFAULTS INITIALIZATION - OPTIONALS
_arg_approve="off"
_arg_skip_nodes="off"

print_help() {
  printf '%s\n' "EKS cluster script's help msg"
  printf 'Usage: %s [--(no-)approve] [--(no-)skip-nodes] [-h|--help] <version>\n' "$0"
  printf '\t%s\n' "<version>: the EKS version to upgrade the cluster to"
  printf '\t%s\n' "--approve, --no-approve: approves the upgrades (off by default)"
  printf '\t%s\n' "--skip-nodes, --no-skip-nodes: skips the upgrades of the Kubernetes nodes. Skip is recommended if you are upgrading the cluster multiple times since you can upgrade nodes two versions up (off by default)"
  printf '\t%s\n' "-h, --help: Prints help"
}

parse_commandline() {
  _positionals_count=0
  while test $# -gt 0; do
    _key="$1"
    case "$_key" in
    --no-approve | --approve)
      _arg_approve="on"
      test "${1:0:5}" = "--no-" && _arg_approve="off"
      ;;
    --no-skip-nodes | --skip-nodes)
      _arg_skip_nodes="on"
      test "${1:0:5}" = "--no-" && _arg_skip_nodes="off"
      ;;
    -h | --help)
      print_help
      exit 0
      ;;
    -h*)
      print_help
      exit 0
      ;;
    *)
      _last_positional="$1"
      _positionals+=("$_last_positional")
      _positionals_count=$((_positionals_count + 1))
      ;;
    esac
    shift
  done
}

handle_passed_args_count() {
  local _required_args_string="'version'"
  test "${_positionals_count}" -ge 1 || _PRINT_HELP=yes die "FATAL ERROR: Not enough positional arguments - we require exactly 1 (namely: $_required_args_string), but got only ${_positionals_count}." 1
  test "${_positionals_count}" -le 1 || _PRINT_HELP=yes die "FATAL ERROR: There were spurious positional arguments --- we expect exactly 1 (namely: $_required_args_string), but got ${_positionals_count} (the last one was: '${_last_positional}')." 1
}

assign_positional_args() {
  local _positional_name _shift_for=$1
  _positional_names="_arg_version "

  shift "$_shift_for"
  for _positional_name in ${_positional_names}; do
    test $# -gt 0 || break
    eval "$_positional_name=\${1}" || die "Error during argument parsing, possibly an Argbash bug." 1
    shift
  done
}

parse_commandline "$@"
handle_passed_args_count
assign_positional_args 1 "${_positionals[@]}"

PRGDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

. "$PRGDIR/set-config.sh"

CLUSTER_CONFIG="$CLUSTER_HOME/aws-infra/eks/cluster.yaml"

if [ "$_arg_approve" != "on" ]; then
    cecho "Doing a dry run. To perform the actual updates, please run this script with the --approve argument" "strong"
fi

approve_str=''
if [ "$_arg_approve" == "on" ]; then
  approve_str='--approve'
fi

cecho "Upgrading EKS cluster to version $_arg_version..." "info"
sed -E -i "s/version: (.*)$/version: \"$_arg_version\"/" "$CLUSTER_CONFIG"
eksctl upgrade cluster -f "$CLUSTER_CONFIG" $approve_str

cecho "Upgrading kube-proxy..." "info"
eksctl utils update-kube-proxy -f "$CLUSTER_CONFIG" $approve_str

cecho "Upgrading aws-node..." "info"
eksctl utils update-aws-node -f "$CLUSTER_CONFIG" $approve_str

cecho "Upgrading coredns..." "info"
eksctl utils update-coredns -f "$CLUSTER_CONFIG" $approve_str

if [ "$_arg_skip_nodes" != "on" ]; then
    cecho "Upgrading nodes..." "info"
    eksctl get nodegroups --region="$AWS_DEFAULT_REGION" --cluster "$CLUSTER_NAME"  -o json | jq -r '.[].Name' | while read name; do
        cecho "Upgrading nodegroup $name..."
        if [ "$_arg_approve" == "on" ]; then
            eksctl upgrade nodegroup --region="$AWS_DEFAULT_REGION" --cluster="$CLUSTER_NAME" --name="$name" --kubernetes-version="$_arg_version"
        fi
    done
else
    cecho "Skipping node upgrades..." "info"
fi
