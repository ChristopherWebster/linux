#!/usr/bin/env bash
echo $BASH_VERSION

#********************************************************************************
#   run_pipelines
#   This script interacts with the GCP Data Fusion API to execute and monitor the 
#   execution of ALL deployed pipelines in specified environment
#
#   to run the process use ./run_pipelines.sh >> filename.log
#   and tail the logs to monitor progress.
#
#   you'll have to have gcloud auth installed and valid login 
#   enter your password when prompted 
#   
#   this process uses two output files:
#   1. 
#   the run_log.txt which shows all the pipelines which have been run 
#   no matter what the status of the pipeline execution is (completed/failed)
#   Any Pipeline which appears in the run_log will be excluded from execution.
#   this allows us to re-run a subset of the deployed pipelines.
#   2. 
#   the queue_file.txt which is to be deprecated
#********************************************************************************



#######################
# initialise
#######################
RUN_LOG="run_log.txt"
QUEUE_FILE="queue_file.txt"
NEXT_PIPELINE=""

#declare -A RUN_PIPELINES
declare -A PIPELINE_RUNS
declare -A PIPELINE_QUEUE
declare -A PIPELINES_LEFT

export PROJECT="ticsystems-amspec"
export LOCATION="northamerica-northeast1"
export INSTANCE_ID="migration-test"
MAX_PARALLEL=4
RUN_LOG="run_log.txt"
NAMESPACE_ID="LIMS_AMSPEC"

#************************************************************
# Periodically refresh Authorisation Token  
#
#************************************************************
check_auth() 
{
# Get the API endpoint
echo "Fetching the Data Fusion API endpoint..."
export AUTH_TOKEN=$(gcloud auth print-access-token)
export CDAP_ENDPOINT=$(gcloud beta data-fusion instances describe \
  --location="$LOCATION" \
  --project="$PROJECT" \
  --format="value(apiEndpoint)" \
  ${INSTANCE_ID})
  
  
}

# Get the API endpoint
echo "Fetching the Data Fusion API endpoint..."
check_auth

# Get the list of pipelines
echo "Fetching the list of pipelines..."
JSON=$(curl -s -X GET -H "Authorization: Bearer ${AUTH_TOKEN}" "${CDAP_ENDPOINT}/v3/namespaces/${NAMESPACE_ID}/apps")
PIPELINE_LIST=($(echo "$JSON" | jq -r '.[].name' | tr -d '\r'))

echo "Found ${#PIPELINE_LIST[@]} pipelines"
echo "${PIPELINE_LIST[*]}"
echo "${PIPELINE_LIST[@]}" > $QUEUE_FILE
#echo "access_role access_role_attribute" > $QUEUE_FILE


#************************************************************
# read RUN_LOG if it exists and remove pipelines from 
# PIPELINE_QUEUE that have already been executed
#************************************************************
remove_executed_pipelines()
{
# Check if the file exists
if [[ -f "$RUN_LOG" ]]; then
    # Read keys from file into an array, splitting on newlines
    readarray -t keys_to_remove < "$RUN_LOG"

    # Loop through the keys and remove from associative array
    for key in "${keys_to_remove[@]}"; do
        unset PIPELINE_QUEUE[$key]
    done

    echo "Removed keys from PIPELINE_QUEUE array:"
    echo "${keys_to_remove[@]}"

else
    echo "Removal file not found: $RUN_LOG"
fi
}
#************************************************************
#
# read_pipelines_from_file() input QUEUE_FILE="queue_file.txt"
# reads the input file of pipelines.  
# then uses these to generate an associative array of the form 
# 	[pipeline]:[status]
# which is maintained throughout the process.
# 
#************************************************************
read_pipelines_from_file()
{
	echo "read_pipelines_from_file called"
	local pipeline_file=$1
	
		if [[ -f $pipeline_file ]]; then 
		echo "in if statement"
		IFS=$' ' read -r -a PIPELINES < "$pipeline_file"
		echo "all pipelines ${!PIPELINES[@]}"
		for elem in "${!PIPELINES[@]}"
		do
		 value=${PIPELINES[${elem}]}
		 PIPELINE_QUEUE[$value]+="TO_RUN"
		 echo "${elem} : ${elem}"
		done
		
		remove_executed_pipelines
		
		#construct associative array 
		for elem in "${!PIPELINE_QUEUE[@]}"
		do
	     #echo "show elements"
		 echo "${elem} : ${PIPELINE_QUEUE[${elem}]}"
		done
	else
		echo "Error : $pipeline_file is not a file, please run again using a valid input file"
	fi 

	echo "all pipelines ${!PIPELINE_QUEUE[*]}"
}


#*****************************************************************
#
# start_pipeline() input pipeline, auth_token 
# calls the start url from the Data Fusion API 
# traps the response and echos it to the screen
# sleeps briefly
# then calls the get status url 
# adds the run id to the PIPELINE_RUNS array 
# PIPELINE_RUNS["$pipeline"]=$run_id
# and writes the output to the run log
# 
#*****************************************************************
start_pipeline()  {

  
    local pipeline=$1
    local token=$2
    check_auth

    echo "$(date) starting pipeline $pipeline"
    local start_url="${CDAP_ENDPOINT}/v3/namespaces/${NAMESPACE_ID}/apps/${pipeline}/workflows/DataPipelineWorkflow/start"
    echo "executing : [ ${start_url} ]"
    response=$(curl -s -X POST -H "Authorization: Bearer ${token}" -H "Content-Length: 0" "${start_url}")
    echo "response [  $response  ]"
    sleep 5
    
    # Now get the runId from the status endpoint
    echo "create status_url"
    status_url="${CDAP_ENDPOINT}/v3/namespaces/${NAMESPACE_ID}/apps/${pipeline}/workflows/DataPipelineWorkflow/runs?limit=1"
    echo "call status_url"
    status_response=$(curl -s -X GET -H "Authorization: Bearer ${token}" "${status_url}")
    echo "create status_url"
    run_id=$(echo $status_response | jq -r '.[0].runid')
    echo "run id = $run_id"
    if [[ -z "$run_id" || "$run_id" == "null" ]]; then
        echo "Error fetching runId for pipeline $pipeline: $status_response"
        exit 1
    fi
    
    echo "$pipeline" >> $RUN_LOG
    PIPELINE_RUNS["$pipeline"]=$run_id
}

#*****************************************************************
#
# check_pipeline_status() input pipeline="exchange_rate"
# calls the api to establish the current status of a pipeline
# the status can be one of the following 
# "ERROR"
# "COMPLETED"
# "FAILED"
# "KILLED"
# The erorr status is generated internally when the connection
# is lost
# 
#*****************************************************************
check_pipeline_status() {
    local pipeline=$1
    check_auth
    local run_id=${PIPELINE_RUNS[$pipeline]}
    local status_url="${CDAP_ENDPOINT}/v3/namespaces/${NAMESPACE_ID}/apps/${pipeline}/workflows/DataPipelineWorkflow/runs/${run_id}"
    
    response=$(curl -s -X GET -H "Authorization: Bearer ${AUTH_TOKEN}" "${status_url}")
    echo "$(date) pipeline status response = $response"
    if [[ "$response" =~ "Connection Refused" || "$response" =~ "Moved Permanently" ]]; then
        PIPELINE_QUEUE[$pipeline]+="ERROR"
    	status="ERROR"
    	return 1
    else
    	status=$(echo $response | jq -r '.status')
    	echo "$(date) Pipeline $pipeline status: $status"
    	PIPELINE_QUEUE[$pipeline]="$status"
    	if [[ "$status" == "COMPLETED" || "$status" == "FAILED" || "$status" == "KILLED" ]]; then
        	return 0  # Finished
    	else
        	return 1  # Still running
    	fi
    fi 
    
}

#*****************************************************************
#
# fetch_next_pipeline() 
# populates NEXT_PIPELINE with the next logical pipeline to start
# 
# 
#*****************************************************************
fetch_next_pipeline()
{
search_value="TO_RUN"  # Value to search for
#matching_keys=()        # Array to store matching keys

echo "$(date) called fetch_next_pipeline"
for key in "${!PIPELINE_QUEUE[@]}"; do 
    if [[ "${PIPELINE_QUEUE[$key]}" == "$search_value" ]]; then
    
        NEXT_PIPELINE=$key
        return 0
        break	
    fi
done
return 1
}

#*****************************************************************
#
# fetch_pipeline_count() 
# sets PIPELINES_LEFT with all pipelines whose value is TO_RUN
# 
# 
#*****************************************************************
fetch_pipeline_count()
{
search_value="TO_RUN"  # Value to search for

PIPELINES_LEFT=()        # Array to store matching keys
#echo "called fetch_pipeline_count"

for key in "${!PIPELINE_QUEUE[@]}"; do 
	echo "$(date) checking pipelines $key value : ${PIPELINE_QUEUE[$key]}"
    if [[ "${PIPELINE_QUEUE[$key]}" == "$search_value" ]]; then
        PIPELINES_LEFT=("$key")
           
    fi
done

return 0
}


#*****************************************************************
#
# run_all_pipelines() input PIPELINE_QUEUE
# manages the execution of the pipelines in the queue
# checks there are pipelines to run 
# checks the run limit
# 
# 
# 
# 
# 
# 
#*****************************************************************
run_all_pipelines()
{
	local running_pipelines=()
	#echo "run all"
	
	fetch_next_pipeline
	if [[ $? -eq 0 ]]; then
		#echo "there are pipelines to run "
		#if running max limit 
		fetch_pipeline_count
		
		echo "$(date) run all"
		
		while [[ ${#PIPELINES_LEFT[@]} -gt 0 || ${#running_pipelines[@]} -gt 0 ]]; do
			# Launch new pipelines if under max parallel limit
			#echo "in first while...."
			while [[ ${#PIPELINES_LEFT[@]} -gt 0 && ${#running_pipelines[@]} -lt $MAX_PARALLEL ]]; do
			#echo "in second while...."
				
				if fetch_next_pipeline ; then
					start_pipeline "$NEXT_PIPELINE" "$AUTH_TOKEN"
					running_pipelines+=("$NEXT_PIPELINE")
	 				echo "$(date) writing output to queue file [ $NEXT_PIPELINE ]"
					echo "$NEXT_PIPELINE" > $QUEUE_FILE
					sleep 10
					check_pipeline_status "$NEXT_PIPELINE"
				else
				    fetch_pipeline_count
					#echo "fetch_next_pipeline was 1, pipelines left= ${#PIPELINES_LEFT[@]} running pipelines ${#running_pipelines[@]}"
				fi
				
			done
			
			# Check status of running pipelines
			echo "$(date) checking running pipelines ${!running_pipelines[@]}"
			for i in "${!running_pipelines[@]}"; do
				#pipeline="${running_pipelines[$i]}"
				if check_pipeline_status "${running_pipelines[$i]}"; then
					# Pipeline has finished
					
					#echo "unsetting running pipelines ${running_pipelines[$i]}"
					unset running_pipelines[$i]
				else
					echo "$(date) ${running_pipelines[$i]} is still running"
				fi
			done
			
			# update pipelines from the array
			running_pipelines=("${running_pipelines[@]}")
			
			sleep 10  # Wait before next status check
		done
		  
	else
	  echo "pipelines complete."
	fi
	
	

}

#######################
# main
#######################
{
	echo "$(date) started main ..."
	
    #read pipelines from file into pipeline array
	read_pipelines_from_file $QUEUE_FILE
	
	run_all_pipelines
	echo "$(date) end main."
	
}
