#!/bin/bash

#Init local vars
RET=0
L_BASE_PATH=./
OPTIND=1

#functions
#############################################################
usage()
{
	echo "usage: test -p /my/path/here   "
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
    echo "calling loadArgs"
	loadArgs "$@"
	echo "echoing output"
	echo "base bath is [ $L_BASE_PATH ]"

}

#exit 0