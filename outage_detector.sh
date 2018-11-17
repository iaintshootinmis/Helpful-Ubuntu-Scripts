#!/bin/bash

# ABOUT #
#   outage_detector -- detect and provide alerts for API outages
# 
# USAGE #
#   ./outage_detector.sh [path to remediation script]
#
# DESCRIPTION #
#   Run this script in order to test if an API is operational.
#   This script takes 1 optional argument, which is the path to a remediation script. The
#   remedation script is a user-defined script that will attempt to fix the API outage. For
#   example, the remediation script could trigger a re-deployment of your application and 
#   restart the http server. The output of remedation script will be included the outage 
#   notification email.
# 
# SETUP #
#   Configure the variables below to get started.
#   
#   Requires `mailx`
#
#   Consider running the outage_detector in a cronjob. 
#   Example (run the script 1 minute past every hour:
#       1 */1 * * * /path/to/outage_detector.sh /path/to/remediation_script.sh
#
#
# Start of required variables #
endpoint="https://example.com/api/test"
expected_response_size=625 # if the returned content size is less than this value,
                           # then the API call will be considered a failure
mail_sender="myserver@example.com"
mail_recepient="alerts@example.com"
max_alert_frequency=10800 # 10800 seconds in 3 hours
# End of required variables #



response=$(curl -s -o /dev/null -w "%{http_code} %{size_download}" $endpoint)
status_code=$(echo "$response" | cut -f1 -d " ")
content_length=$(echo "$response" | cut -f2 -d " ")

if [ $status_code -ne 200 ]; then
    message="API failure - bad status.
             Returned status=$status_code."
elif [ $content_length -le $expected_response_size ]; then
    message="API failure - bad data response.
             Expected Content-Length=$expected_response_size. 
             Actual Content-Length=$content_length."
fi

if [ -n "$message" ]; then
    if [ ! -f "/tmp/outage_detector.dat" ]; then
        last_alert_time=0
    else
        last_alert_time=$(cat /tmp/outage_detector.dat)
    fi

    current_time=$(date +%s)
    time_since_last_alert=$(( $current_time - $last_alert_time ))

    if [ $time_since_last_alert -gt $max_alert_frequency ]; then
        remediation_attempt_response=$(bash "$1")
        message="$message
        status of attempted remediation: $remediation_attempt_response"

        subject="Outage Detected"
        echo "$message" | mailx -r "$mail_sender" -s "$subject" "$mail_recepient"
        date +%s > /tmp/outage_detector.dat
    fi
fi
