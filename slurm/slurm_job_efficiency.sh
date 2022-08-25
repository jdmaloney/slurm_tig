#!/bin/bash

tfile=$(mktemp /tmp/seff.XXXXXX)
source /etc/telegraf/slurm/slurm_config

jobs=($(mysql -u ${username} -p${password} -D ${database} -e "select id_job,account from ${job_table} where time_end > UNIX_TIMESTAMP(now() - interval 1 hour) and exit_code = '0' and array_task_pending = '0'" | grep -v id_job | sed 's/\t/:/'))

for j in ${jobs[@]}
do
	IFS=":" read jobid account <<< "$(echo "${j}")"
	${slurm_path}/seff ${jobid} > ${tfile}
	user=$(grep "User/Group" ${tfile} | cut -d'/' -f 2 | cut -d' ' -f 2)
	cpu_efficiency=$(grep "CPU Efficiency:" ${tfile} | cut -d' ' -f 3 | cut -d'%' -f 1)
	mem_efficiency=$(grep "Memory Efficiency:" ${tfile} | cut -d' ' -f 3 | cut -d'%' -f 1)
	partition=$(${slurm_path}/sacct -P -X -n -o partition%20 -j ${jobid} | head -n 1)
	end_stamp=$(${slurm_path}/sacct -P -X -n -o End -j ${jobid} | sort -r | head -n 1)
	if [ $(echo $cpu_efficiency | cut -d'.' -f 1) -le 100 ] || [ $(echo $mem_efficiency | cut -d'.' -f 1) -le 100 ]; then
		if [ ${end_stamp} != "Unknown" ]; then
			new_end_time=$(date -d "${end_stamp}" +%s%N | head -n 1)
			if [ -z ${end_time} ] || [ ${new_end_time} -ne ${end_time} ]; then
				end_time="${new_end_time}"
				real_end_time="${new_end_time}"
				n=0
			else
				n=$((n+1))
				mult=$((6000000*n))
				end_time="${new_end_time}"
				real_end_time=$((new_end_time+mult))
			fi
			raw_time=$(grep "CPU Efficiency:" ${tfile} | cut -d' ' -f 5)
			if [ -z "$(echo ${raw_time} | grep "-")" ]; then
				## Less than 1 day of core time
				core_time=$(echo ${raw_time} | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }')
			else
				from_core_days=$(echo ${raw_time} | awk -F- '{print ($1 *86400) }')
				from_core_time=$(echo ${raw_time} | cut -d'-' -f 2 | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }')
				core_time=$((from_core_days+from_core_time))
			fi
	
			if [ "${core_time}" -ne 0 ]; then
			echo "slurm_job_efficiency,user=${user},account=${account},partition=${partition} cpu_efficiency=${cpu_efficiency},mem_efficiency=${mem_efficiency},core_time=${core_time},jobid=${jobid} ${real_end_time}"
			fi
		fi
	fi
done

rm -rf ${tfile}
