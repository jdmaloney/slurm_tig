#!/bin/bash

## Slurm Per Queue Metrics
## Can run on any host that can query the scheduler
## Put telegraf in admin group so it can see all queues; or add telegraf to sudoers and modify script to execute slurm commands with sudo

## Setup temp files and define path to slurm
tfile=$(mktemp /tmp/slurm_node.XXXXXX)
tfile2=$(mktemp /tmp/squeue.XXXXXX)
tfile3=$(mktemp /tmp/nodeinfo.XXXXXX)
slurm_path="/usr/slurm/bin"

##Dump info about all running jobs into a temp file; get the list of all nodes in the system
"${slurm_path}"/squeue -t running -O Partition,NodeList:50,tres-alloc:70,username | grep -v TRES_ALLOC | awk '{print $1","$2","$3","$4}' > "${tfile2}"
all_node_list=($("${slurm_path}"/sinfo -N | grep -v NODELIST | awk '{print $1}' | sort -u | xargs))

## Loop over that list of jobs running and get the data formatted in consistent way
while read -r p; do
	## Checking if job is running on multiple nodes
	p_check=$(echo "${p}" | sed 's/\[/\&/')

	## If it is a multi-node job; handle that here
        if [ -n "$(echo "${p_check}" | grep "&")" ]; then
		partition=$(echo "${p}" | cut -d',' -f 1)
		nlist="$(echo "${p}" | cut -d',' -f 2- | cut -d']' -f 1)]"
		node_list=($("${slurm_path}"/scontrol show hostname "${nlist}" | xargs))
		node_count=$(echo ${#node_list[@]})
		## Job isn't using a GPU so run this
		if [ -z "$(echo "${p}" | cut -d',' -f 3- | grep "gpu=")" ]; then
			mem_len=$(echo "${p}" | cut -d'=' -f 3 | sed 's/[^0-9\.]*//g' | wc -c)
                        mem=$(echo "${p}" | cut -d'=' -f 3 | cut -c 1-"${mem_len}")
                        if [ "$(echo "${mem}" | rev | cut -c 1)" == "M" ]; then
              	                t_alloc=$(echo "${mem}" | cut -d'M' -f 1)
				mem_allocated=$(echo "scale=0; ${t_alloc} / ${node_count}" | bc -l)
                        elif [ "$(echo "${mem}" | rev | cut -c 1)" == "G" ]; then
				t_alloc=$(echo "${mem}" | cut -d'G' -f 1)
                                mem_allocated=$(echo "scale=0; ${t_alloc} * 1024 / ${node_count}" | bc -l)
                        else
                                t_alloc=$(echo "${mem}" | cut -d'T' -f 1)
                                mem_allocated=$(echo "scale=0; ${t_alloc} * 1024 * 1024 / ${node_count}" | bc -l)
                        fi
                        raw_cpu=$(echo "${p}" | cut -d'=' -f 2 | cut -d',' -f 1)
			cpu=$(echo "scale=0; ${raw_cpu} / ${node_count}" | bc -l)
			user_name=$(echo "${p}" | rev | cut -d',' -f 1 | rev)
			for n in "${node_list[@]}"
                	do
                        	echo "${n},${partition},${cpu},${mem_allocated},0,${user_name}" >> "${tfile3}"
			done
		## Job uses a GPU(s) so run this
                else
			mem_len=$(echo "${p}" | cut -d'=' -f 3 | grep -o -E '[0-9]+' | head -1 | wc -c)
                        mem=$(echo "${p}" | cut -d'=' -f 3 | cut -c 1-"${mem_len}")
                        if [ "$(echo "${mem}" | rev | cut -c 1)" == "M" ]; then
                                t_alloc=$(echo "${mem}" | cut -d'M' -f 1)
				mem_allocated=$(echo "scale=0; ${t_alloc} / ${node_count}" | bc -l)
                        elif [ "$(echo "${mem}" | rev | cut -c 1)" == "G" ]; then
  	                        t_alloc=$(echo "${mem}" | cut -d'G' -f 1)
				mem_allocated=$(echo "scale=0; ${t_alloc} * 1024 / ${node_count}" | bc -l)
                        else
                        	t_alloc=$(echo "${mem}" | cut -d'T' -f 1)
                        	mem_allocated=$(echo "scale=0; ${t_alloc} * 1024 * 1024 / ${node_count}" | bc -l)
                        fi
			raw_cpu=$(echo "${p}" | cut -d'=' -f 2 | cut -d',' -f 1)
                        cpu=$(echo "scale=0; ${raw_cpu} / ${node_count}" | bc -l)
                        raw_gpu=$(echo "${p}" | cut -d'=' -f 6 | cut -d',' -f 1)
			gpu=$(echo "scale=0; ${raw_gpu} / ${node_count}" | bc -l)
			user_name=$(echo "${p}" | rev | cut -d',' -f 1 | rev)
			for n in "${node_list[@]}"
                	do
                        	echo "${n},${partition},${cpu},${mem_allocated},${gpu},${user_name}" >> "${tfile3}"
			done
                fi
	## The job is not multi-node; continue here as single node
        else
		if [ -z "$(echo "${p}" | cut -d',' -f 3- | grep "gpu=")" ]; then
			mem_len=$(echo "${p}" | cut -d'=' -f 3 | sed 's/[^0-9\.]*//g' | wc -c)
                        mem=$(echo "${p}" | cut -d'=' -f 3 | cut -c 1-"${mem_len}")
			if [ "$(echo "${mem}" | rev | cut -c 1)" == "M" ]; then
		                mem_allocated=$(echo "${mem}" | cut -d'M' -f 1)
	        	elif [ "$(echo "${mem}" | rev | cut -c 1)" == "G" ]; then
		                t_alloc=$(echo "${mem}" | cut -d'G' -f 1)
		                mem_allocated=$(echo "scale=0; ${t_alloc} * 1024" | bc -l)
		        else
		                t_alloc=$(echo "${mem}" | cut -d'T' -f 1)
		                mem_allocated=$(echo "scale=0; ${t_alloc} * 1024 * 1024" | bc -l)
		        fi
			cpu="$(echo "${p}" | cut -d'=' -f 2 | cut -d',' -f 1)"
			partition="$(echo "${p}" | cut -d',' -f 1)"
			node="$(echo "${p}" | cut -d',' -f 2)"
			user_name=$(echo "${p}" | rev | cut -d',' -f 1 | rev)
			echo "${node},${partition},${cpu},${mem_allocated},0,${user_name}" >> "${tfile3}"
		else
			mem_len=$(echo "${p}" | cut -d'=' -f 3 | sed 's/[^0-9\.]*//g' | wc -c)
                        mem=$(echo "${p}" | cut -d'=' -f 3 | cut -c 1-"${mem_len}")
                        if [ "$(echo "${mem}" | rev | cut -c 1)" == "M" ]; then
                                mem_allocated=$(echo "${mem}" | cut -d'M' -f 1)
                        elif [ "$(echo "${mem}" | rev | cut -c 1)" == "G" ]; then
                                t_alloc=$(echo "${mem}" | cut -d'G' -f 1)
                                mem_allocated=$(echo "scale=0; ${t_alloc} * 1024" | bc -l)
                        else
                                t_alloc=$(echo "${mem}" | cut -d'T' -f 1)
                                mem_allocated=$(echo "scale=0; ${t_alloc} * 1024 * 1024" | bc -l)
                        fi
                        cpu=$(echo "${p}" | cut -d'=' -f 2 | cut -d',' -f 1)
			gpu=$(echo "${p}" | cut -d',' -f 7 | cut -d'=' -f 2)
                        partition=$(echo "${p}" | cut -d',' -f 1)
                        node=$(echo "${p}" | cut -d',' -f 2)
			user_name=$(echo "${p}" | rev | cut -d',' -f 1 | rev)
			echo "${node},${partition},${cpu},${mem_allocated},${gpu},${user_name}" >> "${tfile3}"

		fi
        fi
done <"${tfile2}"

## Node Roll Up Stats
"${slurm_path}"/scontrol show nodes | grep 'NodeName\|CfgTRES' > "${tfile}"
"${slurm_path}"/sinfo -N > "${tfile2}"
for n in "${all_node_list[@]}"
do
	cores_avail=$(grep -A1 "NodeName=${n}" "${tfile}" | grep CfgTRES | cut -d'=' -f 3- | cut -d',' -f 1)
	mem=$(grep -A1 "NodeName=${n}" "${tfile}" | grep CfgTRES | cut -d',' -f 2 | cut -d'=' -f 2)
        if [ "$(echo "${mem}" | rev | cut -c 1)" == "M" ]; then
        	mem_avail=$(echo "${mem}" | cut -d'M' -f 1)
        elif [ "$(echo "${mem}" | rev | cut -c 1)" == "G" ]; then
                t_alloc=$(echo "${mem}" | cut -d'G' -f 1)
                mem_avail=$(echo "scale=0; ${t_alloc} * 1024" | bc -l)
        else
                t_alloc=$(echo "${mem}" | cut -d'T' -f 1)
                mem_avail=$(echo "scale=0; ${t_alloc} * 1024 * 1024" | bc -l)
        fi
	if [ -n "$(grep -A1 "NodeName=${n}" "${tfile}" | grep gpu)" ]; then
		gpu_avail=$(grep -A1 "NodeName=${n}" "${tfile}" | grep CfgTRES | cut -d',' -f 4 | cut -d'=' -f 2)
	else
		gpu_avail=0
	fi
	cores_used_agg=0
	mem_used_agg=0
	gpu_used_agg=0
	job_count_agg=0
	partitions_on_node=($(grep "${n}" "${tfile2}" | awk '{print $3}' | xargs))
	for p in "${partitions_on_node[@]}"
	do
		real_p=$(echo "${p}" | sed 's/*//g')
		job_count=$(grep "${n},${real_p}" "${tfile3}" | wc -l)
		job_count_agg=$((job_count_agg+job_count))
		if [ "${job_count}" == "0" ]; then
			cores_used=0
			mem_allocated=0
			gpu_used=0
		else
			cores_used=$(grep "${n},${real_p}" "${tfile3}" | cut -d',' -f 3 | paste -sd+ - | bc)
			mem_allocated=$(grep "${n},${real_p}" "${tfile3}" | cut -d',' -f 4 | paste -sd+ - | bc)
			gpu_used=$(grep "${n},${real_p}" "${tfile3}" | cut -d',' -f 5 | paste -sd+ - | bc)
			cores_used_agg=$((cores_used_agg+cores_used))
			mem_used_agg=$(echo "${mem_used_agg} + ${mem_allocated}" | bc -l)
			gpu_used_agg=$(echo "${gpu_used_agg} + ${gpu_used}" | bc -l)
		fi
		echo "slurm_detail_node_data,node=${n},partition=${real_p} job_count=${job_count},cores_used=${cores_used},mem_allocated=${mem_allocated},cores_avail_total=${cores_avail},mem_avail_total=${mem_avail},gpu_used=${gpu_used},gpu_avail_total=${gpu_avail}"
	done
	echo "slurm_detail_node_data,node=${n},partition=all job_count=${job_count_agg},cores_used=${cores_used_agg},mem_allocated=${mem_used_agg},cores_avail_total=${cores_avail},mem_avail_total=${mem_avail},gpu_used=${gpu_used_agg},gpu_avail_total=${gpu_avail}"
done

## User Roll Up Stats
users_running=($(cat ${tfile3} | rev | cut -d',' -f 1 | rev | sort -u | xargs))
for u in ${users_running[@]}
do
	grep ",${u}" "${tfile3}" > "${tfile2}"
	user_p=($(cat ${tfile2} | cut -d',' -f 2 | sort -u | xargs))
	for p in ${user_p[@]}
	do
		cores_used=$(awk -v part=${p} -F, '$2 == part {print $3}' ${tfile2} | paste -sd+ | bc)
		mem_used=$(awk -v part=${p} -F, '$2 == part {print $4}' ${tfile2} | paste -sd+ | bc)
		gpu_used=$(awk -v part=${p} -F, '$2 == part {print $5}' ${tfile2} | paste -sd+ | bc)
		echo "slurm_user_resource_data,partition=${p},username=${u} cores_used=${cores_used},mem_used_mb=${mem_used},gpus_used=${gpu_used}"
	done
done


rm -rf "${tfile}"
rm -rf "${tfile2}"
rm -rf "${tfile3}"
