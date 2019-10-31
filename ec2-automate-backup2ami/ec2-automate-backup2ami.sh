#!/bin/bash -
# Date: 2017-11-23
# Version 5.0
# License Type: GNU GENERAL PUBLIC LICENSE, Version 3
# Author:
# Colin Johnson / https://github.com/colinbjohnson / colin@cloudavail.com
# Contributors:
# Alex Corley / https://github.com/anthroprose
# Jon Higgs / https://github.com/jonhiggs
# Mike / https://github.com/eyesis
# Jeff Vogt / https://github.com/jvogt
# Dave Stern / https://github.com/davestern
# Josef / https://github.com/J0s3f
# buckelij / https://github.com/buckelij
# jazzl0ver / https://github.com/jazzl0ver

#confirms that executables required for succesful script execution are available
prerequisite_check() {
  for prerequisite in basename cut date ec2-create-image ec2-create-tags ec2-deregister ec2-describe-instances ec2-describe-images ec2-describe-regions; do
    #use of "hash" chosen as it is a shell builtin and will add programs to hash table, possibly speeding execution. Use of type also considered - open to suggestions.
    hash $prerequisite &> /dev/null
    if [[ $? == 1 ]]; then #has exits with exit status of 70, executable was not found
      echo "=== In order to use $app_name, the executable \"$prerequisite\" must be installed." 1>&2 ; exit 70
    fi
  done
}

#-- iterates the expression until the output is non-zero
wait_until()
{
result=`eval  $* | sed 's/ //g'`
if [[ $result == 0 ]]
then
    sleep 60
    wait_until $*
fi
}

#-- iterates the expression until the output is zero
wait_till()
{
result=`eval  $* | sed 's/ //g'`
if [[ $result != 0 ]]
then
    sleep 60
    wait_till $*
fi
}

#get_IList gets a list of available instances in a specified region
get_IList() {
  case $selection_method in
    instanceid)
      if [[ -z $instanceid ]]; then
        echo "=== The selection method \"instanceid\" (which is $app_name's default selection_method of operation or requested by using the -s instanceid parameter) requires an instanceid (-i instanceid) for operation. Correct usage is as follows: \"-i i-6d6a0527\",\"-s instanceid -i i-6d6a0527\" or \"-i \"i-6d6a0527 i-636a0112\"\" if multiple instances are to be selected." 1>&2 ; exit 64
      fi
      instance_selection_string="$instanceid"
      ;;
    tag)
      if [[ -z $tag ]]; then
        echo "=== The selected selection_method \"tag\" (-s tag) requires a valid tag (-t key=value) for operation. Correct usage is as follows: \"-s tag -t backup=true\" or \"-s tag -t Name=my_tag.\"" 1>&2 ; exit 64
      fi
      instance_selection_string="--filter tag:$tag"
#      instance_selection_string=""
      ;;
    *) echo "=== If you specify a selection_method (-s selection_method) for selecting instances you must select either \"instanceid\" (-s instanceid) or \"tag\" (-s tag)." 1>&2 ; exit 64 ;;
  esac
  #creates a list of all instances that match the selection string from above
  instance_backup_list_complete=$(ec2-describe-instances --show-empty-fields --region $region $instance_selection_string 2>&1)
  #takes the output of the previous command 
  instance_backup_list_result=$(echo $?)
  if [[ $instance_backup_list_result -gt 0 ]]; then
    echo -e "An error occured when running ec2-describe-instances. The error returned is below:\n$instance_backup_list_complete" 1>&2 ; exit 70
  fi
  #returns the list of instances that matched instance_selection_string.
  instance_backup_list=$(echo "$instance_backup_list_complete" | grep ^INSTANCE | cut -f 2)
}

tag_ami_resource() {
    resource_id=$1
    shift
    region=$1
    shift
    tags=$@
    
    # exit if AMI is no longer exists
    ec2-describe-images $resource_id --region $region | grep -q ^BLOCKDEVICEMAPPING || { echo "No blockdevices for $resource_id"; ec2-describe-images $resource_id --region $region > /tmp/.test; exit; }

    echo "=== Tagging AMI $resource_id in $region region with the following tags: $tags"
    ec2-create-tags $resource_id --region $region $tags

    # wait until snapshots become available, then tag them
    snapshots=""
    while [[ ! -n $snapshots ]]; do
	snapshots=$(ec2-describe-images $resource_id --region $region | grep ^BLOCKDEVICEMAPPING | grep "snap" | awk '{print $4}')
	[[ -n $snapshots ]] && break
	# the snapshot ids are not yet available => wait another 5 minutes
	sleep 300
    done
    
    for ec2_snapshot_resource_id in $snapshots; do
        echo "=== Tagging Snapshot $ec2_snapshot_resource_id (AMI: $resource_id) with the following tags: $tags"
        ec2_create_tag_result=$(ec2-create-tags $ec2_snapshot_resource_id --region $region $tags)
	if [[ $? != 0 ]]; then
    	    echo -e "An error occured when running 'ec2-create-tags $ec2_snapshot_resource_id --region $region $tags'. The error returned is below:\n$ec2_create_tag_result" 1>&2
    	fi
    done
}

create_AMI_Tags() {
  ami_id=$1
  instance_region=$2
  ami_region=$3
  original_ami_id=$4

  [[ ! -n $instance_region ]] && instance_region=$region
  [[ ! -n $ami_region ]] && ami_region=$instance_region

  #snapshot tags holds all tags that need to be applied to a given snapshot - by aggregating tags we ensure that ec2-create-tags is called only once
  snapshot_tags=""
  #if $name_tag_create is true then add instance name to the variable $snapshot_tags
  if $name_tag_create; then
    ec2_snapshot_name_loc=$(ec2-describe-instances --region $instance_region ${instance_selected} | grep ^TAG | grep Name | cut -f 5)
    snapshot_tags="$snapshot_tags --tag Name=$ec2_snapshot_name_loc
    ec2_snapshot_group=$(ec2-describe-instances --region $instance_region ${instance_selected} | grep ^TAG | grep Group | cut -f 5)
    if [[ -n $ec2_snapshot_group ]]; then
	snapshot_tags="$snapshot_tags --tag Group=$ec2_snapshot_group"
    fi
  fi
  #if $hostname_tag_create is true then append --tag InitiatingHost=$(hostname -f) to the variable $snapshot_tags
  if $hostname_tag_create; then
    snapshot_tags="$snapshot_tags --tag InitiatingHost=$(hostname -f)"
  fi
  #if $purge_after_date_fe is true, then append $purge_after_date_fe to the variable $snapshot_tags
  if [[ -n $purge_after_date_fe ]]; then
    snapshot_tags="$snapshot_tags --tag PurgeAfterFE=$purge_after_date_fe --tag PurgeAfter=$purge_after_date --tag PurgeAllow=true"
  fi
  #if $user_tags is true, then append Instance=$instance_selected and Created=$date_current to the variable $snapshot_tags
  if $user_tags; then
    snapshot_tags="$snapshot_tags --tag Instance=${instance_selected} --tag Created=$date_current"
  fi

  #if $snapshot_tags is not zero length then set the tag on the snapshot using ec2-create-tags
  if [[ -n $snapshot_tags ]]; then
    if [[ -n $original_ami_id ]]; then
	tag_ami_resource $ami_id $ami_region $snapshot_tags "--tag SourceRegion=$instance_region" &
	tag_ami_resource $original_ami_id $instance_region $snapshot_tags "--tag CopyRegion=$ami_region" &
    else
	#-- if load average for last 5 mins more than 3, wait for 5 minutes before continue
	LA_5min=$(uptime | cut -f5 -d,)
	LA_5min=${LA_5min%.*}
	while [ $LA_5min -ge 1 ]; do
	    echo "=== System is overloaded, waiting for 5 minutes before continue..."
	    sleep 300
	    LA_5min=$(uptime | cut -f5 -d,)
	    LA_5min=${LA_5min%.*}
	done
	tag_ami_resource $ami_id $ami_region $snapshot_tags
    fi
  fi
}

copy_AMI() {
  # copies AMI to another region for extra safety
  random_region=$1
  ec2_snapshot_name_loc=$2

  #if $random_region is not zero length then set do the copy
  if [[ -n $random_region ]]; then
    echo "=== Copying AMI $ec2_ami_resource_id ($ec2_snapshot_name_loc) to randomly selected $random_region region"

    # wait until AMI become available, then copy it
    ami_status=1
    while [ $ami_status -ne 0 ]; do
	ec2-describe-images --region $region $ec2_ami_resource_id --hide-tags | grep ^IMAGE | cut -f5 | grep -q available
	ami_status=$?
	[[ $ami_status -eq 0 ]] && break
	# the ami is not yet available => wait another 10 minutes
	sleep 600
    done

    ec2_copy_ami_result=$(ec2-copy-image --source-region $region --source-ami-id $ec2_ami_resource_id --region $random_region --name $ec2_snapshot_name_loc --description "Backup of $ec2_ami_resource_id from $region region" 2>&1)

    if [[ $? != 0 ]]; then
      echo -e "An error occured when running ec2-copy-image. The error returned is below:\n$ec2_copy_ami_result" 1>&2 ; exit 70
    else
      original_ami_id=$ec2_ami_resource_id
      ec2_ami_resource_id=$(echo "$ec2_copy_ami_result" | grep ^IMAGE | cut -f 2)
      if [ "x$ec2_ami_resource_id" = "x" ]; then
        echo "*** error: AMI ID is empty for copied AMI"
        echo "$ec2_copy_ami_result"
        echo "***"
      fi
      echo "Waiting for copy completed..."
      AMI_AVAIL="ec2-describe-images --region $random_region $ec2_ami_resource_id | grep ^IMAGE | cut -f 5 | grep available | wc -l"
      wait_until $AMI_AVAIL
      create_AMI_Tags $ec2_ami_resource_id $region $random_region $original_ami_id
    fi
  else
    echo "=== Copy_AMI: no region specified (this should never happen)" 1>&2
  fi
}

get_date_binary() {
  #$(uname -o) (operating system) would be ideal, but OS X / Darwin does not support to -o option
  #$(uname) on OS X defaults to $(uname -s) and $(uname) on GNU/Linux defaults to $(uname -s)
  uname_result=$(uname)
  case $uname_result in
    Darwin) date_binary="osx-posix" ;;
    Linux) date_binary="linux-gnu" ;;
    *) date_binary="unknown" ;;
  esac
}

get_purge_after_date_fe() {
case $purge_after_input in
  #any number of numbers followed by a letter "d" or "days" multiplied by 86400 (number of seconds in a day)
  [0-9]*d) purge_after_value_seconds=$(( ${purge_after_input%?} * 86400 )) ;;
  #any number of numbers followed by a letter "h" or "hours" multiplied by 3600 (number of seconds in an hour)
  [0-9]*h) purge_after_value_seconds=$(( ${purge_after_input%?} * 3600 )) ;;
  #any number of numbers followed by a letter "m" or "minutes" multiplied by 60 (number of seconds in a minute)
  [0-9]*m) purge_after_value_seconds=$(( ${purge_after_input%?} * 60 ));;
  #no trailing digits default is days - multiply by 86400 (number of minutes in a day)
  *) purge_after_value_seconds=$(( $purge_after_input * 86400 ));;
esac
#based on the date_binary variable, the case statement below will determine the method to use to determine "purge_after_days" in the future
case $date_binary in
  linux-gnu) echo $(date -d +${purge_after_value_seconds}sec -u +%s) ;;
  osx-posix) echo $(date -v +${purge_after_value_seconds}S -u +%s) ;;
  *) echo $(date -d +${purge_after_value_seconds}sec -u +%s) ;;
esac
}

get_purge_after_date()
{
#based on the date_binary variable, the case statement below will determine the method to use to determine "purge_after_days" in the future
case $date_binary in
	linux-gnu) echo `date -d "@${purge_after_date_fe}" -u +%Y-%m-%d` ;;
#	osx-posix) echo `date -j "${purge_after_date_fe}" -u +%Y-%m-%d` ;;
	*) echo `date -d "${purge_after_date_fe}" -u +%Y-%m-%d` ;;
esac
}

get_purge_after_date_epoch()
{
#based on the date_binary variable, the case statement below will determine the method to use to determine "purge_after_date_epoch" in the future
case $date_binary in
	linux-gnu) echo `date -d $purge_after_date +%s` ;;
	osx-posix) echo `date -j -f "%Y-%m-%d" $purge_after_date "+%s"` ;;
	*) echo `date -d $purge_after_date +%s` ;;
esac
}

get_date_current_epoch()
{
#based on the date_binary variable, the case statement below will determine the method to use to determine "date_current_epoch" in the future
case $date_binary in
	linux-gnu) echo `date -d $date_current +%s` ;;
	osx-posix) echo `date -j -f "%Y-%m-%d" $date_current "+%s"` ;;
	*) echo `date -d $date_current +%s` ;;
esac
}

purge_AMIs() {
  # snapshot_tag_list is a string containing any snapshot that contains
  # either the key PurgeAllow or the key PurgeAfterFE
  # note that filtering for *both* keys is a requirement or else the
  # PurgeAfterFE key/value pair will not be returned
  ami_tag_list=$(ec2-describe-tags --show-empty-fields --region $region --filter resource-type=image --filter key=PurgeAllow,PurgeAfterFE)
  # snapshot_purge_allowed is a string containing Snapshot IDs that are
  # allowed to be purged
  #snapshot_purge_allowed=$(echo "$ami_tag_list" | grep .*PurgeAllow'\s'true | cut -f 3)
  # if running under CentOS 5 - note the use of "grep -P" in the comment below
  # use of grep -P is not used because it breaks compatibility with OS X
  # Mavericks
  ami_purge_allowed=$(echo "$ami_tag_list" | grep -P "^.*PurgeAllow\strue$" | cut -f 3)

  for ami_id_evaluated in $ami_purge_allowed; do
    #gets the "PurgeAfterFE" date which is in UTC with UNIX Time format (or xxxxxxxxxx / %s)
    purge_after_fe=$(echo "$ami_tag_list" | grep -P .*$ami_id_evaluated'\s'PurgeAfterFE.* | cut -f 5)
    #if purge_after_date is not set then we have a problem. Need to alert user.
    if [[ -z $purge_after_fe ]]; then
      #Alerts user to the fact that a Snapshot was found with PurgeAllow=true but with no PurgeAfterFE date.
      echo "=== AMI with the AMI ID \"$ami_id_evaluated\" has the tag \"PurgeAllow=true\" but does not have a \"PurgeAfterFE=xxxxxxxxxx\" key/value pair. $app_name is unable to determine if $ami_id_evaluated should be purged." 1>&2
    else
      # PurgeAfterFE is earlier than today
      # and the snapshot can be safely purged
      if [[ $current_date > $purge_after_fe ]]; then
        # get appropriate snapshot-ids firstly
#        snapshot_purge_list=$(ec2-describe-images --region $region $ami_id_evaluated | grep BLOCKDEVICEMAPPING | awk '{print $4}')

        echo "=== AMI \"$ami_id_evaluated\" with the PurgeAfterFE date of \"$purge_after_fe\" will be deleted."
        ec2-deregister --region $region $ami_id_evaluated
#        wait_till "ec2-describe-images --region $region $ami_id_evaluated | wc -l"

	# purge snapshots of the selected AMI
#	for snapshot_id_evaluated in $snapshot_purge_list; do
#    	    echo "=== Snapshot \"$snapshot_id_evaluated\" of the AMI \"$ami_id_evaluated\" will be deleted."
#    	    ec2-delete-snapshot --region $region $snapshot_id_evaluated
#    	done
      fi
    fi
  done
}

purge_EBS_Snapshots() {
  # snapshot_tag_list is a string containing any snapshot that contains
  # either the key PurgeAllow or the key PurgeAfterFE
  # note that filtering for *both* keys is a requirement or else the
  # PurgeAfterFE key/value pair will not be returned
  snapshot_tag_list=$(ec2-describe-tags --show-empty-fields --region $region --filter resource-type=snapshot --filter key=PurgeAllow,PurgeAfterFE)
  # snapshot_purge_allowed is a string containing Snapshot IDs that are
  # allowed to be purged
  #snapshot_purge_allowed=$(echo "$snapshot_tag_list" | grep .*PurgeAllow'\s'true | cut -f 3)
  # if running under CentOS 5 - note the use of "grep -P" in the comment below
  # use of grep -P is not used because it breaks compatibility with OS X
  # Mavericks
  snapshot_purge_allowed=$(echo "$snapshot_tag_list" | grep -P "^.*PurgeAllow\strue$" | cut -f 3)

  for snapshot_id_evaluated in $snapshot_purge_allowed; do
    #gets the "PurgeAfterFE" date which is in UTC with UNIX Time format (or xxxxxxxxxx / %s)
    purge_after_fe=$(echo "$snapshot_tag_list" | grep -P .*$snapshot_id_evaluated'\s'PurgeAfterFE.* | cut -f 5)
    #if purge_after_date is not set then we have a problem. Need to alert user.
    if [[ -z $purge_after_fe ]]; then
      #Alerts user to the fact that a Snapshot was found with PurgeAllow=true but with no PurgeAfterFE date.
      echo "=== Snapshot with the Snapshot ID \"$snapshot_id_evaluated\" has the tag \"PurgeAllow=true\" but does not have a \"PurgeAfterFE=xxxxxxxxxx\" key/value pair. $app_name is unable to determine if $snapshot_id_evaluated should be purged." 1>&2
    else
      # if $purge_after_fe is less than $current_date then
      # PurgeAfterFE is earlier than the current date
      # and the snapshot can be safely purged
      # we postpone EBS snapshot removal to the next day, since corresponding AMI removal might not be completed yet
      if [[ $purge_after_fe+86400 < $current_date ]]; then
        echo "=== Snapshot \"$snapshot_id_evaluated\" with the PurgeAfterFE date of \"$purge_after_fe\" will be deleted."
        ec2-delete-snapshot --region $region $snapshot_id_evaluated
      fi
    fi
  done
}

process_instance() {
    ec2_snapshot_name_loc=$ec2_snapshot_name
    ec2_snapshot_description_loc=$ec2_snapshot_description
    instance_selected_loc=$instance_selected

    echo "=== Starting: ec2-create-image -v -n $ec2_snapshot_name_loc --no-reboot --region $region -d $ec2_snapshot_description_loc $instance_selected_loc"
    ec2_create_ami_result=$(ec2-create-image -n "$ec2_snapshot_name_loc" -v --no-reboot --region $region -d "$ec2_snapshot_description_loc" $instance_selected_loc 2>&1)
    if [[ $? != 0 ]]; then
      echo -e "An error occured when running ec2-create-image $ec2_snapshot_name_loc. The error returned is below:\n$ec2_create_ami_result" 1>&2
    else
      ec2_ami_resource_id=$(echo "$ec2_create_ami_result" | grep ^IMAGE | cut -f 2)
      create_AMI_Tags $ec2_ami_resource_id $region
      [[ -z $make_copy_tag ]] && continue
      ec2-describe-instances --region $region ${instance_selected_loc} --filter tag:$make_copy_tag | grep -q INSTANCE
      make_copy=$?
      if [[ $make_copy -eq 0 ]]; then
	#-- if load average for last 5 mins more than 3, wait for 5 minutes before continue
	LA_5min=$(uptime | cut -f5 -d,)
	LA_5min=${LA_5min%.*}
	while [ $LA_5min -ge 1 ]; do
	    echo "=== System is overloaded, waiting for 5 minutes before continue..."
	    sleep 300
	    LA_5min=$(uptime | cut -f5 -d,)
	    LA_5min=${LA_5min%.*}
	done
        copy_AMI $random_region $ec2_snapshot_name_loc
      fi
    fi
}

app_name=$(basename $0)
#sets defaults
selection_method="instanceid"
#date_binary allows a user to set the "date" binary that is installed on their system and, therefore, the options that will be given to the date binary to perform date calculations
date_binary=""
#sets the "Name" tag set for a snapshot to false - using "Name" requires that ec2-create-tags be called in addition to ec2-create-snapshot
name_tag_create=false
#sets the "InitiatingHost" tag set for a snapshot to false
hostname_tag_create=false
#sets the user_tags feature to false - user_tag creates tags on snapshots - by default each snapshot is tagged with instanceid and date_current timestamp
user_tags=false
#sets the Purge Snapshot feature to false - if purge_snapshots=true then snapshots will be purged
purge_snapshots=false
#do not make a copy of an AMI to a random region
make_copy=false
#handles options processing

while getopts :s:c:r:i:t:k:y:o:pnhu opt; do
  case $opt in
    s) selection_method="$OPTARG" ;;
    c) cron_primer="$OPTARG" ;;
    r) regions="$OPTARG" ;;
    v) instanceid="$OPTARG" ;;
    t) tag="$OPTARG" ;;
    k) purge_after_input="$OPTARG" ;;
    y) make_copy_tag="$OPTARG" ;;
    o) other_regions="$OPTARG" ;;
    n) name_tag_create=true ;;
    h) hostname_tag_create=true ;;
    p) purge_snapshots=true ;;
    u) user_tags=true ;;
    *) echo "=== Error with Options Input. Cause of failure is most likely that an unsupported parameter was passed or a parameter was passed without a corresponding option." 1>&2 ; exit 64 ;;
  esac
done

#sources "cron_primer" file for running under cron or other restricted environments - this file should contain the variables and environment configuration required for ec2-automate-backup to run correctly
#if [[ -n $cron_primer ]]; then
#  if [[ -f $cron_primer ]]; then
#    source $cron_primer
#  else
#    echo "Cron Primer File \"$cron_primer\" Could Not Be Found." 1>&2 ; exit 70
#  fi
#fi

#if region is not set then:
if [[ -z $regions ]]; then
  #if the environment variable $EC2_REGION is not set set to all possible regions
  if [[ -z $EC2_REGION ]]; then
    regions=$(ec2-describe-regions | grep REGION | cut -f2)
  else
    regions=$EC2_REGION
  fi
fi

#calls prerequisitecheck function to ensure that all executables required for script execution are available
prerequisite_check

#sets date variable
current_date=$(date -u +%s)
date_current=$(date -u +%Y-%m-%d)

#sets the PurgeAfterFE and PurgeAfter tags to the number of seconds that a snapshot should be retained
if [[ -n $purge_after_input ]]; then
  #if the date_binary is not set, call the get_date_binary function
  if [[ -z $date_binary ]]; then
    get_date_binary
  fi
  purge_after_date_fe=$(get_purge_after_date_fe)
  purge_after_date=$(get_purge_after_date)
  echo "=== Snapshots taken by $app_name will be eligible for purging after the following date (the purge after date given in seconds from epoch): $purge_after_date_fe ($purge_after_date)."
fi

for region in $regions; do
  echo "=== Region: $region"

  if [[ -n $make_copy_tag ]]; then
    if [[ -z $other_regions ]]; then
	other_regions=$(ec2-describe-regions | grep REGION | grep -v $region | cut -f2)
    fi
    arr=($other_regions)
    other_regions_count=${#arr[*]}
    random=$(/usr/bin/shuf -i 1-${other_regions_count} -n 1)
    random_region=${arr[$random-1]}
    echo "=== Copy Region: $random_region"
  fi

  #get_IList gets a list of AMIs for which a snapshot is desired. The list of AMIs depends upon the selection_method that is provided by user input
  get_IList
  
#  instance_backup_list="i-a379294d"

  #the loop below is called once for each volume in $ebs_backup_list - the currently selected EBS volume is passed in as "ebs_selected"
  for instance_selected in $instance_backup_list; do
    ec2_snapshot_description="ec2ab_${instance_selected}_$date_current"
    ec2_snapshot_name=$(ec2-describe-instances --region $region ${instance_selected} | grep ^TAG | grep Name | cut -f 5)
    ec2_snapshot_name="ec2ab_${ec2_snapshot_name}_$date_current"
    process_instance &
  done

  #if purge_snapshots is true, then run purge_EBS_Snapshots function
  if $purge_snapshots; then
    echo "=== AMI Purging is Starting Now."
    purge_AMIs
    echo "=== Snapshot Purging is Starting Now."
    purge_EBS_Snapshots
  fi

done

echo "=== All's been done"
