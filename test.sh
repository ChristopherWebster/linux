#!/bin/bash

#Init local vars
RET=0
L_BASE_PATH=./
#initialise OPTIND - not reset on multiple calls in all Linux versions
OPTIND=1


# Configuration
error_log="error.log"  # Set the error log file path

# Set a trap to call handle_error on ERR signal
trap 'handle_error' ERR

#functions
#############################################################
usage()
{
	echo "usage: test -p /my/path/here   "
}
#############################################################
# Error handling function
handle_error() {
  local err_code=$?     # Get the exit code of the last command
  local err_msg="$1"    # Optional custom error message

  # Log the error with timestamp
  echo "$(date +'%Y-%m-%d %H:%M:%S') - Error ($err_code): ${err_msg:-Unknown error}" >> "$error_log"

  # Additional actions (e.g., send notification, cleanup, etc.) can be added here
}
#############################################################
loadArgs()
{
	while getopts ":p:h" args; do
		case $args in
			p)
        L_BASE_PATH=${OPTARG}
				;;

			h)
        usage
        ;;

      \?)
      	echo "Error: incorrect parameter provided"
        #usage
        usage >&2
        exit 1
        ;;
    esac
	done
	shift $((OPTIND-1))
}


###################################################################



###################################################################
# Main
###################################################################
{
# Main script logic
echo "Starting script..."
  echo "calling loadArgs"
	loadArgs "$@"
	echo "echoing output"
	echo "base bath is [ $L_BASE_PATH ]"

	###################################################################	
	# Example commands that might fail and trigger the error handler...
	#false  
	#ls /nonexistent_file
	#invalid_command
        ###################################################################
	
echo "Script finished."

}

#exit 0
