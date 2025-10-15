#!/usr/bin/env bash

progress-bar(){

   local current=$1
   local len=$2

   local bar_char='#'
   local empty_char='.'
   local percent_done=$((current*100/len))
   local length=50
   local num_bars=$((percent_done * length / 100))



   local i
   local s='['
   for ((i = 0; i < num_bars; i++)); do
        s+='\e[31m'$bar_char'\e[0m'
   done
   for ((i = num_bars; i < length;i++)); do
       s+=$empty_char
   done
   s+=']'

   echo -ne "$s $current/$len ($percent_done%)\r"  

}

process-file(){
    local file=$1
    sleep .01
}

shopt -s globstar nullglob

echo 'finding files'
#find . -name '*cache'

files=(./**/*cache)
len=${#files[@]}

echo "found $len files"
i=0
for file in "${files[@]}"; do

        progress-bar "$((i+1))" "$len"

        process-file "$file"
        #echo "$file"
        ((i++))
done

echo
