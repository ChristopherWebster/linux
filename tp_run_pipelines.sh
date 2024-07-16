
#!/bin/bash
# vim: set ts=4 sts=4 sw=4 et ai:
# be strict

RED='\033[0;31m'
GRN='\033[0;32m'
BLU='\033[1;34m'
CLR='\033[0m'

set -e

execute_psql() {
  local command="$1"
  local msg=''

  log_msg "Executing [${1}]"
  EXECUTED=$(eval "${command}" 2>&1 || true)
  if echo "${EXECUTED}" | tr '[:upper:]' '[:lower:]' | grep "psql:.*error:" 1>/dev/null; then
      msg="$(echo "${EXECUTED}" | tr '[:upper:]' '[:lower:]' | grep 'psql:.*error:')"

      log_msg "${EXECUTED}"
      log_msg "$(basename "$0") Failed executing [${1}]"
      log_msg "${msg}"
      exit 1
  fi
  log_msg "Success"
}

show_help() {
    echo -e "***${RED}run_pipelines.sh will attempt to connect to the specified Data Fusion instance and execute any and all pipelines in the specified namespace.${CLR}***"
    echo -e
    echo -e "${BLU}You will need to have access to the instance and appropriate GCP user permissions in order to execute this script.${CLR}"
    echo -e
    echo -e "${BLU}If the process is interrupted, re-running the script (without a database) will attempt to continue by reading the 'run_pipelines_recover_file.log' which stores the successfully completed pipelines.${CLR}"
    echo -e
    echo -e "${BLU}Once all pipelines have run successfully, the 'run_pipelines_recover_file.log' will be automatically deleted.${CLR}"
    echo -e
    echo -e "${BLU}To authenticate against GCP, run 'gcloud auth application-default login'. Once the script starts, you may be asked to reauthenticate (your password will not be stored).${CLR}"
    echo -e
    echo -e "Usage: ${GRN}run_pipelines.sh${CLR} [${GRN}-h${CLR}][${GRN}-d${CLR} <database>][${GRN}-H${CLR} <host>][${GRN}-P${CLR} <port>][${GRN}-i${CLR} <instance>][${GRN}-n${CLR} <namespace>][${GRN}-l${CLR} <location>][${GRN}-p${CLR} <project>][${GRN}-U${CLR} <username>]"
    echo -e
    echo -e " ${GRN}-h  ${BLU}show this help info"
    echo -e
    echo -e " ${GRN}-d  ${BLU}database which will be the target of the pipelines - if provided, triggers a truncate (defaults to empty)"
    echo -e
    echo -e " ${GRN}-i  ${BLU}instance (defaults to migration-test)"
    echo -e
    echo -e " ${GRN}-n  ${BLU}namespace (defaults to LIMS_AMSPEC)"
    echo -e
    echo -e " ${GRN}-l  ${BLU}location (defaults to northamerica-northeast1)"
    echo -e
    echo -e " ${GRN}-p  ${BLU}project (defaults to ticsystems-amspec)"
    echo -e
    echo -e " ${GRN}-H  ${BLU}host (defaults to empty)"
    echo -e
    echo -e " ${GRN}-P  ${BLU}port (defaults to empty)"
    echo -e
    echo -e " ${GRN}-U  ${BLU}username (defaults to postgres)"
    echo -e "${CLR}"
}

declare -A RUN_IDS
declare -A START_TIMES
declare -a PROCESSING
declare -a ALL_PIPELINES
declare -a TO_DO
declare -a COMPLETED
declare -a FAILED

START_DATE_TS=0
RUN_DATE=$(date +"%m_%d_%Y_%H_%M_%S")
RUN_DATE_HUMAN=$(date +"%m-%d-%Y %H:%M:%S")

MAX_PARALLEL=30
TOKEN_LIFETIME=3600
MAX_LAST_RUN_AGE=10800

AUTH_TOKEN=""
CDAP_ENDPOINT=""
SECONDS=0
CHECK_AUTH="TRUE"
RECOVERY=""

NAMESPACE_ID="LIMS_AMSPEC"
PROJECT="ticsystems-amspec"
LOCATION="northamerica-northeast1"
INSTANCE_ID="migration-test"
HOST=''
PORT=''
ADMINUSER='postgres'
DATABASE=""
DIR=$(dirname "$0")
SCRIPTS_DIRECTORY=${DIR}/'../scripts'
while getopts :h?n:p:l:i:d:H:P:U: opt; do
    case $opt in
        d)
            DATABASE=$(echo "$OPTARG" | tr '[:upper:]' '[:lower:]')
        ;;
        H)
            HOST=$(echo "$OPTARG" | tr '[:upper:]' '[:lower:]')
        ;;
        P)
            PORT=$OPTARG
        ;;
        U)
            ADMINUSER=$OPTARG
        ;;
        n)
            NAMESPACE_ID=$OPTARG
        ;;
        p)
            PROJECT=$OPTARG
        ;;
        l)
            LOCATION=$OPTARG
        ;;
        i)
            INSTANCE_ID=$OPTARG
        ;;
        h|?)
            show_help
            exit
        ;;
        *)
            show_help
            exit
        ;;
    esac
done
shift "$((OPTIND-1))"

if [[ -z $DATABASE ]];
then
    echo -e "${RED}Missing mandatory arguments: ${BLU}database${RED}.${CLR}"
    exit 1
fi
if [[ -z $NAMESPACE_ID ]];
then
    echo -e "${RED}Missing mandatory arguments: ${BLU}namespace${RED}.${CLR}"
    exit 1
fi
if [[ -z $PROJECT ]];
then
    echo -e "${RED}Missing mandatory arguments: ${BLU}project${RED}.${CLR}"
    exit 1
fi
if [[ -z $LOCATION ]];
then
    echo -e "${RED}Missing mandatory arguments: ${BLU}region${RED}.${CLR}"
    exit 1
fi
if [[ -z $INSTANCE_ID ]];
then
    echo -e "${RED}Missing mandatory arguments: ${BLU}instance${RED}.${CLR}"
    exit 1
fi

PSQL_ARGS="-U ${ADMINUSER} -v ON_ERROR_STOP=1"
if [[ -n $HOST ]]; then
  PSQL_ARGS="-h ${HOST} ${PSQL_ARGS}"
fi
if [[ -n $PORT ]]; then
  PSQL_ARGS="-p ${PORT} ${PSQL_ARGS}"
fi

CLIENT_DB_PSQL_ARGS="-d ${DATABASE} -U ${ADMINUSER}"
RECOVER_FILE="run_pipelines_recover_file_${DATABASE}.log"
LOG="run_pipelines_log_${DATABASE}_${RUN_DATE}.log"
FAILED_LOG="run_pipeline_failed_log_${DATABASE}_${RUN_DATE}.log"

log_msg() {
  local msg="$1"
  local log_only="${2:-default}"
  local function=""

  len=${#FUNCNAME[@]}
  if (( len == 1 )); then
    function="${FUNCNAME[0]}"
  else
    function="${FUNCNAME[1]}"
  fi

  if [[ "${log_only}" == "log" ]]; then
    printf "[$(date +"%m-%d-%Y %H:%M:%S.%N")] [%s] %s\n" >> "${LOG}" "${function}" "${msg}"
  else
    printf "[$(date +"%m-%d-%Y %H:%M:%S.%N")] [%s] %s\n" >> "${LOG}" "${function}" "${msg}"
    echo -e "$(date +"%m-%d-%Y %H:%M:%S.%N") ${BLU}[${GRN}${function}${BLU}] ${msg}${CLR}"
  fi
}

set_max_parallel() {
  log_msg "MAX_PARALLEL currently at [ ${MAX_PARALLEL} ]"

  MAX_PARALLEL=${#PROCESSING[@]}

  log_msg "Set MAX_PARALLEL to [ ${MAX_PARALLEL} ]"
}

truncate_table_only() {
  local pipeline=$1

  # Only truncate if we're recovering
  if [[ -n $RECOVERY ]]; then
    log_msg "Truncating table [ ${pipeline} ] as in recovery mode"

    execute_psql "psql ${CLIENT_DB_PSQL_ARGS} ${PSQL_ARGS} -c 'set role ts_admin; truncate table ts_client_data.${pipeline};'"
  fi
}

add_to_to_do() {
  local pipeline=$1
  local current_pipeline=""
  local add="TRUE"

  log_msg "Currently [ ${#TO_DO[@]} ] in TO_DO array" "log"

  for current_pipeline in "${TO_DO[@]}"; do
    if [[ ${current_pipeline} == "${pipeline}" ]]; then
      add=""
      log_msg "Pipeline [ ${pipeline} ] already in  TO_DO array" "log"
      break
    fi
  done

  if [[ -n ${add} ]]; then
    TO_DO+=("${pipeline}")
    log_msg "Now [ ${#TO_DO[@]} ] in TO_DO array" "log"

    log_msg "Added [ ${pipeline} ] to TO_DO array" "log"
  fi
}

add_to_run_ids() {
  local pipeline=$1
  local run_id=$2

  log_msg "Currently [ ${#RUN_IDS[@]} ] in RUN_IDS array" "log"
  RUN_IDS[$pipeline]+="${run_id}"
  log_msg "Now [ ${#RUN_IDS[@]} ] in RUN_IDS array" "log"

  log_msg "Added [ ${pipeline} ] with run_id [ ${run_id} ] to RUN_IDS"
}

remove_from_run_ids() {
  local pipeline=$1

  log_msg "Currently [ ${#RUN_IDS[@]} ] in RUN_IDS array" "log"

  unset ${RUN_IDS[$pipeline]}

  log_msg "Removed [ ${pipeline} ] from RUN_IDS array - [ ${#RUN_IDS[@]} ] items remaining" "log"
}

handle_resource_limited() {
  local pipeline=$1

  log_msg "Possible resource limitation encountered, resetting pipeline [ ${pipeline} ]"

  # First, truncate the table for the pipeline
  truncate_table_only "${pipeline}"

  # Second, add the pipeline back to the TO_DO queue and remove from the PROCESSING and RUN_IDS queue
  remove_from_processing "${pipeline}"
  add_to_to_do "${pipeline}"
  remove_from_run_ids "${pipeline}"

  # Third, turn down the MAX_PARALLEL to the current size of the PROCESSING queue
  set_max_parallel
}

truncate_db() {
  if [[ -z $RECOVERY ]]; then
    log_msg "Attempting to truncate target database [ ${DATABASE} ]"
    execute_psql "psql ${CLIENT_DB_PSQL_ARGS} ${PSQL_ARGS} -f ${SCRIPTS_DIRECTORY}/truncateDB.sql"
  fi
}

validate_json() {
  local test_string=$1

  if jq -e . >/dev/null 2>&1 <<<"${test_string}"; then
    return 0
  fi

  log_msg "Received invalid json [ ${test_string} ]"

  return 1
}

log_total_time() {
  local time=$1
  local msg=$2
  local h_tag="hours"
  local m_tag="minutes"
  local s_tag="seconds"
  local h m s mm
  local string=""

  s=$(( time%60 ))
  mm=$(( time/60 ))
  m=$(( mm%60 ))
  h=$(( mm/60 ))

  if [[ "$h" -eq "1" ]]; then
    h_tag="hour"
  fi
  if [[ "$m" -eq "1" ]]; then
    m_tag="minute"
  fi
  if [[ "$s" -eq "1" ]]; then
    s_tag="second"
  fi
  if [[ "$h" -gt "0" ]]; then
    string="$h ${h_tag}"
  fi
  if [[ "$time" -ge "60" ]]; then
    string="$string $m ${m_tag} and"
  fi

  log_msg "${msg} ${string} ${s} ${s_tag}"
}

remove_from_to_do() {
  local pipeline=$1
  local new_array=()

  for i in "${!TO_DO[@]}"; do
    if [[ ${TO_DO[$i]} != "${pipeline}" ]]; then
      new_array+=("${TO_DO[$i]}")
    fi
  done

  TO_DO=("${new_array[@]}")

  log_msg "Removed [ ${pipeline} ] from TO_DO array - [ ${#TO_DO[@]} ] items remaining"
}

add_to_processing() {
  local pipeline=$1
  local current_pipeline=""
  local add="TRUE"

  remove_from_to_do "${pipeline}"

  log_msg "Currently [ ${#PROCESSING[@]} ] in PROCESSING array" "log"
  for current_pipeline in "${PROCESSING[@]}"; do
    if [[ ${current_pipeline} == "${pipeline}" ]]; then
      add=""
      log_msg "Pipeline [ ${pipeline} ] already in  PROCESSING array" "log"
      break
    fi
  done

  if [[ -n ${add} ]]; then
    PROCESSING+=("${pipeline}")

    log_msg "Now [ ${#PROCESSING[@]} ] in PROCESSING array" "log"

    log_msg "Added [ ${pipeline} ] to PROCESSING array"
  fi
}

remove_from_processing() {
  local pipeline=$1
  local new_array=()

  for i in "${!PROCESSING[@]}"; do
    if [[ ${PROCESSING[$i]} != "${pipeline}" ]]; then
      new_array+=("${PROCESSING[$i]}")
    fi
  done

  PROCESSING=("${new_array[@]}")

  log_msg "Removed [ ${pipeline} ] from PROCESSING array - [ ${#PROCESSING[@]} ] items remaining" "log"
}

add_to_start_times() {
  local pipeline=$1
  local start_time=0

  start_time=$(date +%s)

  log_msg "Currently [ ${#START_TIMES[@]} ] in START_TIMES array" "log"
  START_TIMES[$pipeline]+="${start_time}"
  log_msg "Now [ ${#START_TIMES[@]} ] in START_TIMES array" "log"

  log_msg "Added [ ${pipeline} ] with start time [ ${start_time} ] to START_TIMES array"
}

remove_from_start_times() {
  local pipeline=$1

  log_msg "Currently [ ${#START_TIMES[@]} ] in RUN_IDS array" "log"

  unset ${START_TIMES[$pipeline]}

  log_msg "Removed [ ${pipeline} ] from START_TIMES array - [ ${#START_TIMES[@]} ] items remaining" "log"
}

add_to_completed() {
  local pipeline=$1
  local current_pipeline=""
  local add="TRUE"

  log_msg "Currently [ ${#COMPLETED[@]} ] in COMPLETED array" "log"

  for current_pipeline in "${COMPLETED[@]}"; do
    if [[ ${current_pipeline} == "${pipeline}" ]]; then
      add=""
      log_msg "Pipeline [ ${pipeline} ] already in  COMPLETED array" "log"
      break
    fi
  done

  if [[ -n ${add} ]]; then
    COMPLETED+=("${pipeline}")
    log_msg "Now [ ${#COMPLETED[@]} ] in COMPLETED array" "log"

    log_msg "Added [ ${pipeline} ] to COMPLETED array" "log"
  fi
}

add_to_failed() {
  local pipeline=$1
  local current_pipeline=""
  local add="TRUE"

  log_msg "Currently [ ${#FAILED[@]} ] in FAILED array" "log"

  for current_pipeline in "${FAILED[@]}"; do
    if [[ ${current_pipeline} == "${pipeline}" ]]; then
      add=""
      log_msg "Pipeline [ ${pipeline} ] already in  FAILED array" "log"
      break
    fi
  done

  if [[ -n ${add} ]]; then
    FAILED+=("${pipeline}")
    log_msg "Now [ ${#FAILED[@]} ] in FAILED array" "log"

    log_msg "Added [ ${pipeline} ] to FAILED array" "log"
  fi
}

add_to_all() {
  local pipeline=$1
  local current_pipeline=""
  local add="TRUE"

  log_msg "Currently [ ${#ALL_PIPELINES[@]} ] in ALL_PIPELINES array" "log"

  for current_pipeline in "${ALL_PIPELINES[@]}"; do
    if [[ ${current_pipeline} == "${pipeline}" ]]; then
      add=""
      log_msg "Pipeline [ ${pipeline} ] already in  ALL_PIPELINES array" "log"
      break
    fi
  done

  if [[ -n ${add} ]]; then
    ALL_PIPELINES+=("${pipeline}")
    log_msg "Now [ ${#ALL_PIPELINES[@]} ] in ALL_PIPELINES array" "log"

    log_msg "Added [ ${pipeline} ] to ALL_PIPELINES array" "log"
  fi
}

add_to_recover_file() {
  local pipeline=$1

  echo "${pipeline}" >> "${RECOVER_FILE}"

  log_msg "Added [ ${pipeline} ] to RECOVER_FILE" "log"
}

add_to_failed_log() {
  local pipeline=$1

  echo "${pipeline}" >> "${FAILED_LOG}"

  log_msg "Added [ ${pipeline} ] to FAILED_LOG" "log"
}

record_completed_pipeline() {
  local pipeline=$1

  remove_from_processing "${pipeline}"

  add_to_completed "${pipeline}"

  add_to_recover_file "${pipeline}"
}

record_failed_pipeline() {
  local pipeline=$1
  local response=$2

  log_msg "Recording failure of pipeline [ ${pipeline} ]"

  remove_from_processing "${pipeline}"

  add_to_failed "${pipeline}"

  add_to_failed_log "${pipeline}"
}

retrieve_cdap_endpoint() {
  log_msg "Retrieving Cloud Data Fusion Endpoint"

  CDAP_ENDPOINT=$(gcloud beta data-fusion instances describe \
    --location="${LOCATION}" \
    --project="${PROJECT}" \
    --format="value(apiEndpoint)" \
    "${INSTANCE_ID}")

  export CDAP_ENDPOINT

  API_URL_ROOT="${CDAP_ENDPOINT}/v3/namespaces/${NAMESPACE_ID}/apps"
  API_URL_BRANCH="workflows/DataPipelineWorkflow"
  API_URL_RUNS="${API_URL_BRANCH}/runs"
  API_URL_START="${API_URL_BRANCH}/start"
}

check_auth() {
  local ten_minutes_left=$(( TOKEN_LIFETIME - 600 ))

  if (( SECONDS >= ten_minutes_left )); then
    log_msg "More than [ ${ten_minutes_left} ] seconds (token lifetime is [ ${TOKEN_LIFETIME} ]) since last auth check, forcing login"
    CHECK_AUTH="TRUE"
  fi

  if [[ -n $CHECK_AUTH ]]; then
    log_msg "Authorizing"

    eval gcloud auth login

    AUTH_TOKEN=$(gcloud auth print-access-token)
    export AUTH_TOKEN

    log_msg "Authenticated"

    SECONDS=0
    CHECK_AUTH=""

    # Update the CDAP url on each refreshed authentication
    retrieve_cdap_endpoint
  fi
}

remove_completed_pipelines_from_to_do() {
  for pipeline in "${COMPLETED[@]}"; do
    log_msg "Removing COMPLETED pipeline [ ${pipeline} ] from TO_DO"
    remove_from_to_do "${pipeline}"
  done
}

check_recovery_file() {
	log_msg "Checking for recovery file"

  if [[ -f $RECOVER_FILE ]]; then
    log_msg "Found recovery file, populating COMPLETED array"
    readarray -t COMPLETED < ${RECOVER_FILE}

    log_msg "Found [ ${#COMPLETED[@]} ] COMPLETED pipelines from last run"

    RECOVERY="TRUE"
    log_msg "Set recovery mode"
  else
    log_msg "No recovery file found"
  fi
}

populate_pipelines() {
  get_pipelines_from_namespace

  TO_DO=("${ALL_PIPELINES[@]}")

  log_msg "Added [ ${#TO_DO[@]} ] pipelines to TO_DO"

  check_recovery_file

	remove_completed_pipelines_from_to_do
}

pipeline_has_run_id() {
  local pipeline=$1
  local run_id=""

  log_msg "Checking for existing run_id for pipeline [ ${pipeline} ]"

  for pipeline_run in "${!RUN_IDS[@]}"; do
    if [[ $pipeline_run == "${pipeline}" ]]; then
      run_id="${RUN_IDS[$pipeline]}"
    fi
  done

  if [[ -n $run_id ]]; then
    log_msg "Found run_id for pipeline [ ${pipeline} ]"
    return 0
  else
    log_msg "No existing run_id for pipeline [ ${pipeline} ]"
    return 1
  fi
}

has_connection_error() {
  local response=$1

  if [[ "${response}" =~ "Connection Refused" || "${response}" =~ "Moved Permanently" ]]; then
    return 1
  fi

  return 0
}

check_resource_failure() {
  local pipeline=$1
  local total_time=0
  local func_output=0
  local end_time_ts=0

  log_msg "Checking time since start for pipeline [ ${pipeline} ]"

  end_time_ts=$(date +%s)

  total_time=$((end_time_ts - START_TIMES[$pipeline]))

  if [[ $total_time -lt 180 ]]; then
    # Pipelines failing in less than 3 minutes are likely to be failing because of a resource issue
    log_msg "Pipeline [ ${pipeline} ] failed in 180 seconds or less"
    handle_resource_limited "${pipeline}"
  else
    # Some other failure type, so record as regular fail
    record_failed_pipeline "${pipeline}"
  fi
}

pipeline_end_time_within_limit() {
  local end_time=$1
  local diff=0

  log_msg "Checking end time within last run limit"

  diff=$(( START_DATE_TS - end_time ))

  log_msg "End time was [ ${diff} ] seconds ago"

  if [[ $diff -lt $MAX_LAST_RUN_AGE ]]; then
    log_msg "End time within limit of [ ${MAX_LAST_RUN_AGE} ]"
    return 0
  fi

  log_msg "End time exceeds limit of [ ${MAX_LAST_RUN_AGE} ]"

  return 1
}

store_run_id() {
  local pipeline=$1
  local status_url=$2
  local status_response=""
  local run_id=""
  local add=""

  if pipeline_has_run_id "${pipeline}"; then
    run_id=${RUN_IDS[$pipeline]}
  else
    status_response=$(curl -s -X GET -H "Authorization: Bearer ${AUTH_TOKEN}" "${status_url}")

    validate_json "${status_response}"
    func_output=$?
    if [[ $func_output -eq 0 ]];then
      run_id=$(echo "${status_response}" | jq -r '.[].runid')
      add="TRUE"
    fi
  fi

  if [[ -z "$run_id" || "$run_id" == "null" ]]; then
    log_msg "Error fetching run_id for pipeline [ $pipeline ]: ${status_response}"
    record_failed_pipeline "${pipeline}"
  else
    log_msg "Run id [ ${run_id} ] found for pipeline [ ${pipeline} ]"

    if [[ -n ${add} ]]; then
      add_to_run_ids "${pipeline}" "${run_id}"
    fi
  fi
}

check_pipeline_status() {
  local pipeline=$1
  local url="${API_URL_ROOT}/${pipeline}/${API_URL_RUNS}?limit=1"
  local func_output=0
  local status="ERROR"
  local run_id=""
  local response=""

  if pipeline_has_run_id "${pipeline}"; then
    url="${API_URL_ROOT}/${pipeline}/${API_URL_RUNS}/${RUN_IDS[$pipeline]}"
    run_id="${RUN_IDS[$pipeline]}"
  fi

  log_msg "Checking current status of pipeline [ ${pipeline} ]"

  log_msg "Executing [ ${url} ]" "log"

  response=$(curl -s -X GET -H "Authorization: Bearer ${AUTH_TOKEN}" "${url}")

  log_msg "Status response [ ${response} ]" "log"

  validate_json "${response}"
  func_output=$?
  if [[ $func_output -eq 0 ]];then

    log_msg "Status response is valid json" "log"

    has_connection_error "${response}"
    func_output=$?
    if [[ $func_output -eq 1 ]]; then
      log_msg "Status check failed due to connection error for pipeline [ ${pipeline} ]"

      record_failed_pipeline "${pipeline}"
    else
      if [[ -n ${run_id} ]]; then
        status=$(echo "${response}" | jq -r '.status')
      else
        status=$(echo "${response}" | jq -r '.[0].status')
      fi
    fi

    if [[ -z ${status} ]]; then
      log_msg "No pipeline status found"
      exit 1
    fi

    log_msg "Pipeline [ ${pipeline} ] has status [ ${status} ]"

    if [[ "${status}" ==  "PENDING" ]]; then
      if [[ -z ${run_id} ]]; then
        store_run_id "${pipeline}" "${url}"
        add_to_processing "${pipeline}"
      fi
    elif [[ "${status}" ==  "PROVISIONING" ]]; then
      if [[ -z ${run_id} ]]; then
        store_run_id "${pipeline}" "${url}"
        add_to_processing "${pipeline}"
      fi
    elif [[ "${status}" ==  "STARTING" ]]; then
      if [[ -z ${run_id} ]]; then
        store_run_id "${pipeline}" "${url}"
        add_to_processing "${pipeline}"
      fi
    elif [[ "${status}" ==  "RUNNING" ]]; then
      if [[ -z ${run_id} ]]; then
        store_run_id "${pipeline}" "${url}"
        add_to_processing "${pipeline}"
      fi
    elif [[ "${status}" ==  "COMPLETED" ]]; then
      if [[ -n ${run_id} ]]; then
        start_time=$(echo "${response}" | jq -r '.starting')
        end_time=$(echo "${response}" | jq -r '.end')
      else
        start_time=$(echo "${response}" | jq -r '.[0].starting')
        end_time=$(echo "${response}" | jq -r '.[0].end')
      fi

      log_msg "Pipeline [ ${pipeline} ] start time [ ${start_time} ]"
      log_msg "Pipeline [ ${pipeline} ] end time [ ${end_time} ]"

      if pipeline_end_time_within_limit "${end_time}"; then
        if [[ -z ${run_id} ]]; then
          add_to_processing "${pipeline}"
        fi
        record_completed_pipeline "${pipeline}"

        log_total_time $((end_time - start_time)) "Pipeline [ ${pipeline} ] completed in "
      fi
    elif [[ "${status}" ==  "FAILED" ]]; then
      # Did this fail in this run (i.e., is there currently a run id for it)?
       if [[ -n ${run_id} ]]; then
        # If this failed because of a resource problem, the failure should be near enough immediate
        check_resource_failure "${pipeline}"
      else
        # This is an old failure so carry on (i.e., return 0 for no current status)
        log_msg "No run id for [ ${status} ] pipeline [ ${pipeline} ], treating as expired/out of date status"
        log_msg "Ensuring pipeline is in the TO_DO list"

        remove_from_processing "${pipeline}"
        add_to_to_do "${pipeline}"
        remove_from_run_ids "${pipeline}"

      fi
    fi

  else
    # Invalid json (authentication problem, most likely)
    record_failed_pipeline "${pipeline}"
  fi
}

start_pipeline() {
  local pipeline=$1
  local url="${API_URL_ROOT}/${pipeline}/${API_URL_START}"

  log_msg "Starting pipeline [ ${pipeline} ]"

  log_msg "Executing [ ${url} ]" "log"

  response=$(curl -s -X POST -H "Authorization: Bearer ${AUTH_TOKEN}" -H "Content-Length: 0" "${url}")

  log_msg "Received response [ ${response} ]" "log"

  add_to_start_times "${pipeline}"

  add_to_processing "${pipeline}"

  log_msg "Started pipeline [ ${pipeline} ]"
}

start_next_pipeline() {
    local pipeline=""
    local response=""
    local func_output=0

    log_msg "PROCESSING queue has [ ${#PROCESSING[@]} ] of [ ${MAX_PARALLEL} ]"

    # Get the first item from the TO_DO - other way wasn't being reliable so...yeah
    for i in "${!TO_DO[@]}"; do
      pipeline="${TO_DO[$i]}"
      break
    done

    # Is this pipeline already doing something (did we restart after a problem)?
    if [[ -n ${pipeline} ]]; then
      check_pipeline_status "${pipeline}"

      for pipeline_to_do in "${TO_DO[@]}"; do
        if [[ ${pipeline} == "${pipeline_to_do}" ]];then

          # Before we start the pipeline for the table, truncate it if we're recovering
          truncate_table_only "${pipeline}"

          start_pipeline "${pipeline}"

          log_msg "Sleeping for 5"
          sleep 5

          # Check to see what happened with the attempt to start the pipeline - handles instances where the resources are
          # limited already
          check_pipeline_status "${pipeline}"
        fi
      done

      log_msg "Pipeline [ ${pipeline} ] active"
    fi
}

check_running_pipelines() {
    local pipeline=""

    log_msg "There are [ ${#PROCESSING[@]} ] pipelines being processed"

    for pipeline in "${PROCESSING[@]}"; do

      check_pipeline_status "${pipeline}"

    done
}

process_to_do() {

  local loop="TRUE"
  log_msg "Processing TO_DO"

  while [[ -n $loop ]]; do

    check_auth

    log_msg "There are [ ${#TO_DO[@]} ] unprocessed pipelines remaining"

    # Set up any new pipelines on this iteration
    while [[ ${#PROCESSING[@]} -lt $MAX_PARALLEL ]] && [[ ${#TO_DO[@]} -gt 0 ]]; do
      start_next_pipeline
    done

    # Check running pipelines on this iteration
    check_running_pipelines

    # Wait for a bit
    log_msg "Sleeping for 10"
    log_msg "Re-authentication required in [ $(( TOKEN_LIFETIME - 600 - SECONDS )) ] seconds"
    log_msg "Processing [ ${#PROCESSING[@]} ] with [ ${#TO_DO[@]} ] still to do"
    sleep 10

    log_msg "TO_DO currently [ ${#TO_DO[@]} ], PROCESSING currently [ ${#PROCESSING[@]} ]" "log"
    # Check if both the TO_DO and PROCESSING arrays are empty yet
    if [[ ${#TO_DO[@]} -gt 0 || ${#PROCESSING[@]} -gt 0 ]]; then
      loop="TRUE"
      log_msg "Continuing to process pipelines"
    else
      loop=""
      log_msg "All TO_DO and PROCESSING pipelines completed"
    fi

  done
}

get_pipelines_from_namespace() {
  log_msg "Fetching the list of pipelines in the [ ${NAMESPACE_ID} ] namespace"

  JSON=$(curl -s -X GET -H "Authorization: Bearer ${AUTH_TOKEN}" "${API_URL_ROOT}")

  validate_json "${JSON}"
  func_output=$?
  if [[ $func_output -eq 0 ]];then
    ALL_PIPELINES=($(echo "$JSON" | jq -r '.[].name' | tr -d '\r'))

    log_msg "Found [ ${#ALL_PIPELINES[@]} ] pipelines in namespace [ ${NAMESPACE_ID} ]"
    log_msg "[${ALL_PIPELINES[*]}]"
  else
    log_msg "Failed to get all pipelines, exiting"
    exit 1
  fi
}

delete_recover_file() {
   # If there are no FAILED items, delete the recover file
    if [[ ${#FAILED[@]} == 0 ]]; then
      rm "${RECOVER_FILE}"
    fi
}

runtime () {
  local end_time_ts=0
  local end_time_human=0
  local string=""

  check_auth

  START_DATE_TS=$(date +%s)

  log_msg "Bash Version: [ ${BASH_VERSION} ]"

  log_msg "Started at: [ ${RUN_DATE_HUMAN} ]"

  populate_pipelines

  process_to_do

  delete_recover_file

  end_time_ts=$(date +%s)
  end_time_human=$(date +"%m_%d_%Y_%H_%M_%S")
  log_msg "Ended at: [ ${end_time_human} ]"
  log_total_time $((end_time_ts - START_DATE_TS)) "Total run time"

  log_msg "Completed: [ ${#COMPLETED[@]} ] of ${#ALL_PIPELINES[@]}"
  string="${FAILED[*]}"
  log_msg "Failed: [ ${string} ]"
}


# First check if this run is a follow up (naive check for the presence of the file
check_recovery_file

# Next, truncate the whole database if there were no COMPLETED pipelines
truncate_db

# Finally, run the pipelines
runtime
