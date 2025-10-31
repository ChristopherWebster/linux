#!/usr/bin/env bash
#
#  My basic shell script template. 
#  C. Webster 31 October 2025
#  Creadit Dave Eddy ysap.com for the user env reference using the users bash shell rather than 
#  hard coded bash. This has advantages in system executed shell scripts where the system user 
#  running the script uses a particular shell.
#
#

#formatting:
# Reset
Colour_Off='\033[0m'       # Text Reset

# Regular Colors
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green
Yellow='\033[0;33m'       # Yellow
Blue='\033[0;34m'         # Blue
Purple='\033[0;35m'       # Purple
Cyan='\033[0;36m'         # Cyan
White='\033[0;37m'        # White 

# High Intensity
IBlack='\033[0;90m'       # Black
IRed='\033[0;91m'         # Red
IGreen='\033[0;92m'       # Green
IYellow='\033[0;93m'      # Yellow
IBlue='\033[0;94m'        # Blue
IPurple='\033[0;95m'      # Purple
ICyan='\033[0;96m'        # Cyan
IWhite='\033[0;97m'       # White

set -e

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
	echo -e "${IRed}usage${Colour_Off}: ${ICyan}test -p ${IYellow}/my/path/here${Colour_Off}   "
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
      	echo -e "${IRed}Error: incorrect parameter provided${Colour_Off}"
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
