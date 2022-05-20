#!/bin/bash

tfile=$(mktemp /tmp/sacct.XXXXXX)
source /etc/telegraf/scripts/slurm/slurm_config

if [ -z "$password" ]
then
  # ASSUME NO PASSWORD NECESSARY, e.g. USING SOCKET
  mysqlpass=""
else
  mysqlpass="-p${password}"
fi

## Get data into temp files for parsing
mysql -u ${username} ${mysqlpass} -D ${database} -e "select id_user,account,\`partition\`,tres_req,(time_end - time_start), time_end from ${job_table} where time_end > UNIX_TIMESTAMP(now() - interval 2 hour) and exit_code = '0' and array_task_pending = '0'" | tail -n +2 | sed 's/\t/:/g' > ${tfile}
mysql -u ${username} ${mysqlpass} -D ${database} -e "select id,type,\`name\` from tres_table where deleted = '0'" | sed 's/\t/:/g' > ${tfile}.tres

old_job_end=0
many_same=0
id_user=""
while IFS= read -r line; do
	resource_usage_string=""
	IFS=":" read -r id_user account partition tres_raw job_time_seconds job_end_time <<< "${line}"

	## Map username
	if [ "${id_user}" != "${old_id_user}" ]; then
		pretty_id_user=$(getent passwd ${id_user} | cut -d':' -f 1)
	fi

	## Handle jobs that end at same exact second by incrementing their timestamp by 1 microsecond
	njob_end_time="${job_end_time}000"
	if [ ${old_job_end} -eq ${job_end_time} ]; then
		if [ ${many_same} -eq 0 ]; then
			add_num=1
			many_same=1
		else
			add_num=$((many_same+1))
			many_same=${add_num}
		fi
		njob_end_time=$((njob_end_time+add_num))
	else
		many_same=0
	fi
	old_job_end=${job_end_time}

	## Walk through all tres/gres resource ids for tracking
	ids=($(echo ${tres_raw} | sed 's/,/\n/g' | cut -d'=' -f 1 | xargs))
	for i in ${ids[@]}
	do
		if [ -z $(awk -F : -v id=${i} '$1 == id {print $0}' ${tfile}.tres | grep gres) ]; then
			## Not a GRES
			field=$(awk -F : -v id=${i} '$1 == id {print $2}' ${tfile}.tres)
			field_value=$(echo ${tres_raw} | sed 's/,/\n/g' | awk -F = -v id=${i} '$1 == id {print $2}')
			field_seconds=$(echo "scale=5; ${field_value} * ${job_time_seconds}" | bc -l)
			resource_usage_string="$(echo ${resource_usage_string}),${field}_seconds=${field_seconds}"
		else
			## Is a GRES
			field=$(awk -F : -v id=${i} '$1 == id {print $3"_"$4}' ${tfile}.tres)
                        field_value=$(echo ${tres_raw} | sed 's/,/\n/g' | awk -F = -v id=${i} '$1 == id {print $2}')
                        field_seconds=$(echo "scale=5; ${field_value} * ${job_time_seconds}" | bc -l)
                        resource_usage_string="$(echo ${resource_usage_string}),${field}_seconds=${field_seconds}"
		fi
	done

	## Clean up the resource string and echo final output
	resource_usage_string=$(echo ${resource_usage_string} | cut -d',' -f 2- | sed 's/__/_/g')
	old_id_user=${id_user}
	echo "slurm_job_accounting_data,partition=${partition},user=${pretty_id_user},account=${account} ${resource_usage_string} ${njob_end_time}"
done < <(cat "${tfile}")

rm -rf "${tfile}"
