#!/bin/bash

tfile=$(mktemp /tmp/seff.XXXXXX)
source /etc/telegraf/slurm_config

jobs=($(mysql -u ${username} -p${password} -D ${database} -e "select id_job from ${job_table} where time_end > UNIX_TIMESTAMP(now() - interval 1 hour) and exit_code = '0' and array_task_pending = '0'" | grep -v id_job))

for j in ${jobs[@]}
do
	${slurm_path}/seff ${j} > ${tfile}
	user=$(grep "User/Group" ${tfile} | cut -d'/' -f 2 | cut -d' ' -f 2)
	group=$(grep "User/Group" ${tfile} | cut -d'/' -f 3)
	cpu_efficiency=$(grep "CPU Efficiency:" ${tfile} | cut -d' ' -f 3 | cut -d'%' -f 1)
	mem_efficiency=$(grep "Memory Efficiency:" ${tfile} | cut -d' ' -f 3 | cut -d'%' -f 1)
	partition=$(${slurm_path}/sacct -P -X -n -o partition%20 -j ${j})
	end_stamp=$(${slurm_path}/sacct -P -X -n -o End -j ${j})
	end_time=$(date -d "${end_stamp}" +%s%N | head -n 1)
	raw_time=$(grep "CPU Efficiency:" ${tfile} | cut -d' ' -f 5)
	if [ -z "$(echo ${raw_time} | grep "-")" ]; then
		## Less than 1 day of core time
		core_time=$(echo ${raw_time} | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }')
	else
		from_core_days=$(echo ${raw_time} | awk -F- '{print ($1 *86400) }')
		from_core_time=$(echo ${raw_time} | cut -d'-' -f 2 | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }')
		core_time=$((from_core_days+from_core_time))
	fi

	echo "${j}"
	echo "slurm_job_efficiency,user=${user},group=${group},partition=${partition} cpu_efficiency=${cpu_efficiency},mem_efficiency=${mem_efficiency},core_time=${core_time} ${end_time}"
done

rm -rf ${tfile}
