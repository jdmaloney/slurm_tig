#!/bin/bash

## High Level Slurm Metrics
## Can run on any host that can query the scheduler
## Put telegraf in admin group so it can see all queues; or add telegraf to sudoers and modify script to execute slurm commands with sudo

source /etc/telegraf/slurm/slurm_config
tfile1=$(mktemp /tmp/slurm1.XXXXXX)
tfile2=$(mktemp /tmp/slurm2.XXXXXX)
tfile3=$(mktemp /tmp/slurm3.XXXXXX)

## Get data and measure slurm's responsiveness while doing so
partitions=($({ time "${slurm_path}"/sinfo -h | awk '{print $1}' | sort -u | xargs | sed 's/*//g';} 2>${tfile1}.time))
sinfo_response=$(awk '$1 == "real" {print $2}' ${tfile1}.time | sed 's/.*m\(.*\)s/\1/')

{ time "${slurm_path}"/squeue -a -h -l;} 2> ${tfile1}.time 1> ${tfile1}
"${slurm_path}"/squeue -h -l -O Partition,Username,State > ${tfile2}
squeue_response=$(awk '$1 == "real" {print $2}' ${tfile1}.time | sed 's/.*m\(.*\)s/\1/')

echo "slurm_responsiveness squeue_response_seconds=${squeue_response},sinfo_response_seconds=${sinfo_response}"

## Aggregate Node Stats
IFS="/" read nodes_busy nodes_idle nodes_offline nodes_total <<< "$("${slurm_path}"/sinfo -h -o %F)"
echo "slurm_nodesumdata,partition=all nodes_busy=${nodes_busy},nodes_idle=${nodes_idle},nodes_offline=${nodes_offline},nodes_total=${nodes_total}"
${slurm_path}/sinfo -o %R,%D,%T | tr -cd '[:alnum:],-_\n' > "${tfile3}"

max_jobs=$("${slurm_path}"/scontrol show config | grep MaxJobCount | cut -d' ' -f 15)
total_jobs=$(cat ${tfile1} | wc -l)
running_jobs=$(cat ${tfile1} | grep RUNNING | wc -l )
pending_jobs=$(cat ${tfile1} | grep PENDING | wc -l )
percent_max=$(echo "${total_jobs} / ${max_jobs} *100" | bc -l)
echo "slurm_jobsumdata,partition=all running_jobs=${running_jobs},pending_jobs=${pending_jobs},total_jobs=${total_jobs},max_jobs=${max_jobs},percent_of_max_jobs=${percent_max}"

pend_line="slurm_jobsumdata,partition=all,type=pendingbyreason "
found_pending=0
while IFS= read -r line; do
        found_pending=1
        IFS=" " read -r pend_job_count pend_reason <<< "${line}"
        pend_line="${pend_line},${pend_reason}=${pend_job_count}"
done < <(awk '{print $9}' ${tfile1} | awk '$1 ~ /\(/ {print $0}' | sort | uniq -c | sed 's/^ *//g' | tr -d '()' | sed 's/,//g')
if [ ${found_pending} -eq 1 ]; then
        final_pend_line=$(echo ${pend_line} | sed 's/\ ,/\ /')
        echo "${final_pend_line}"
fi

## For each partition get job information and user information
for p in ${partitions[@]}
do
	total_jobs=$(awk -v p="$p" '$1==p {print $0}' ${tfile2} | wc -l)
	running_jobs=$(awk -v p="$p" '$1==p {print $0}' ${tfile2} | awk '$3 == "RUNNING" {print $0}' | wc -l )
	pending_jobs=$(awk -v p="$p" '$1==p {print $0}' ${tfile2} | awk '$3 == "PENDING" {print $0}' | wc -l )
	echo "slurm_jobsumdata,partition=${p} running_jobs=${running_jobs},pending_jobs=${pending_jobs},total_jobs=${total_jobs}"

	pend_line="slurm_jobsumdata,partition=${p},type=pendingbyreason "
        found_pending=0
        while IFS= read -r line; do
                found_pending=1
                IFS=" " read -r pend_job_count pend_reason <<< "${line}"
                pend_line="${pend_line},${pend_reason}=${pend_job_count}"
        done < <(awk -v partition=${p} '$2 == partition {print $9}' ${tfile1} | awk '$1 ~ /\(/ {print $0}' | sort | uniq -c | sed 's/^ *//g' | tr -d '()' | sed 's/,//g')
        if [ ${found_pending} -eq 1 ]; then
                final_pend_line=$(echo ${pend_line} | sed 's/\ ,/\ /')
                echo "${final_pend_line}"
        fi

	state_string=""
        states=($(grep ^${p}, ${tfile3} | cut -d',' -f 3 | sort | uniq))
        for s in ${states[@]}
        do
                count=$(grep ^${p}, ${tfile3} | grep ,${s}$ | cut -d',' -f 2 | paste -sd+ | bc)
                state_string="${state_string},${s}=${count}"
        done
        final_state=$(echo ${state_string} | cut -c 2-)

        echo "slurm_partition_node_state,partition=${p} ${final_state}"

	IFS="/" read alloc_nodes idle_nodes offline_nodes total_nodes <<< "$("${slurm_path}"/sinfo -h --partition="$p" -o %F)"

	if [ -z "${alloc_nodes}" ]; then
		echo "slurm_nodedata,partition=${p} nodes_busy=0,nodes_idle=0,nodes_offline=0,nodes_total=0,percent_offline=0"
	else
		percent_offline=$(echo "${offline_nodes} / ${total_nodes} * 100" | bc -l)
		echo "slurm_nodedata,partition=${p} nodes_busy=${alloc_nodes},nodes_idle=${idle_nodes},nodes_offline=${offline_nodes},nodes_total=${total_nodes},percent_offline=${percent_offline}"
	fi

	users=($(awk '{print $2}' ${tfile2} | sort -u))
	for u in ${users[@]}
	do
		count_running=$(awk -v u="$u" '$2==u {print $0}' ${tfile2} | awk -v p="$p" '$1==p {print $0}' | awk '$3 == "RUNNING"' |  wc -l)
		count_pending=$(awk -v u="$u" '$2==u {print $0}' ${tfile2} | awk -v p="$p" '$1==p {print $0}' | awk '$3 == "PENDING"' | wc -l)
		if [ $count_running -ne 0 ]; then
			echo "slurm_userjobdata,partition=${p},type=running,user=${u} count=$count_running"
		fi
		if [ $count_pending -ne 0 ]; then
                        echo "slurm_userjobdata,partition=${p},type=pending,user=${u} count=$count_pending"
                fi
	done

done

## Backfill & Scheduler Stats
"${slurm_path}"/sdiag > ${tfile1}

IFS=" " read slurm_server_thread_count slurm_agent_queue_size slurm_agent_count slurm_agent_thread_count slurm_dbd_agent_queue_size slurm_jobs_submitted slurm_jobs_started slurm_jobs_completed slurm_jobs_canceled slurm_jobs_failed <<< "$(grep -A 12 "Data since" ${tfile1} | tail -n +3 | cut -d':' -f 2 | sed -e 's/^[[:space:]]*//' | xargs)"

IFS=" " read slurm_last_cycle_time slurm_max_cycle_time slurm_total_cycles slurm_mean_cycle slurm_mean_depth_cycle slurm_cycles_per_minute slurm_last_queue_length <<< "$(grep -A 7 "Main schedule statistics" ${tfile1} | tail -n +2 | cut -d':' -f 2 | sed -e 's/^[[:space:]]*//' | xargs)"

if [ $(${slurm_path}/squeue -t pending | wc -l) -lt 2 ]; then
	IFS=" " read slurm_tot_backfill_jobs_from_start slurm_tot_backfill_jobs_from_cycle slurm_backfill_het_job_components slurm_total_cycles_backfill slurm_last_cycle_backfill slurm_max_cycle_backfill slurm_last_depth_cycle_backfill slurm_last_depth_cycle_try_backfill slurm_last_queue_length_backfill slurm_last_table_size_backfill <<< "$(grep -A 11 "Backfilling stats" ${tfile1} | tail -n +2 | grep -v "Last cycle when" | cut -d':' -f 2- | sed -e 's/^[[:space:]]*//' | xargs)"

	echo "slurm_scheduler_data slurm_server_thread_count=${slurm_server_thread_count},slurm_agent_queue_size=${slurm_agent_queue_size},slurm_agent_count=${slurm_agent_count},slurm_agent_thread_count=${slurm_agent_thread_count},slurm_dbd_agent_queue_size=${slurm_dbd_agent_queue_size},slurm_jobs_submitted=${slurm_jobs_submitted},slurm_jobs_started=${slurm_jobs_started},slurm_jobs_completed=${slurm_jobs_completed},slurm_jobs_canceled=${slurm_jobs_canceled},slurm_jobs_failed=${slurm_jobs_failed},slurm_last_cycle_time=${slurm_last_cycle_time},slurm_max_cycle_time=${slurm_max_cycle_time},slurm_total_cycles=${slurm_total_cycles},slurm_mean_cycle=${slurm_mean_cycle},slurm_mean_depth_cycle=${slurm_mean_depth_cycle},slurm_cycles_per_minute=${slurm_cycles_per_minute},slurm_last_queue_length=${slurm_last_queue_length},slurm_tot_backfill_jobs_from_start=${slurm_tot_backfill_jobs_from_start},slurm_tot_backfill_jobs_from_cycle=${slurm_tot_backfill_jobs_from_cycle},slurm_backfill_het_job_components=${slurm_backfill_het_job_components},slurm_total_cycles_backfill=${slurm_total_cycles_backfill},slurm_last_cycle_backfill=${slurm_last_cycle_backfill},slurm_max_cycle_backfill=${slurm_max_cycle_backfill},slurm_mean_cycle_backfill=0,slurm_last_depth_cycle_backfill=${slurm_last_depth_cycle_backfill},slurm_last_depth_cycle_try_backfill=${slurm_last_depth_cycle_try_backfill},slurm_depth_mean_backfill=0,slurm_depth_mean_try_backfill=0,slurm_last_queue_length_backfill=${slurm_last_queue_length_backfill},slurm_queue_length_mean_backfill=0,slurm_last_table_size_backfill=${slurm_last_table_size_backfill},slurm_last_mean_table_size_backfill=0"
elif [ $("${slurm_path}"/sdiag | grep -A4 "Backfilling stats" | tail -n 1 | awk '{print $3}') -ne 0 ]; then
	IFS=" " read slurm_tot_backfill_jobs_from_start slurm_tot_backfill_jobs_from_cycle slurm_backfill_het_job_components slurm_total_cycles_backfill slurm_last_cycle_backfill slurm_max_cycle_backfill slurm_mean_cycle_backfill slurm_last_depth_cycle_backfill slurm_last_depth_cycle_try_backfill slurm_depth_mean_backfill slurm_depth_mean_try_backfill slurm_last_queue_length_backfill slurm_queue_length_mean_backfill slurm_last_table_size_backfill slurm_last_mean_table_size_backfill <<< "$(grep -A 16 "Backfilling stats" ${tfile1} | tail -n +2 | grep -v "Last cycle when" | cut -d':' -f 2- | sed -e 's/^[[:space:]]*//' | xargs)"

	echo "slurm_scheduler_data slurm_server_thread_count=${slurm_server_thread_count},slurm_agent_queue_size=${slurm_agent_queue_size},slurm_agent_count=${slurm_agent_count},slurm_agent_thread_count=${slurm_agent_thread_count},slurm_dbd_agent_queue_size=${slurm_dbd_agent_queue_size},slurm_jobs_submitted=${slurm_jobs_submitted},slurm_jobs_started=${slurm_jobs_started},slurm_jobs_completed=${slurm_jobs_completed},slurm_jobs_canceled=${slurm_jobs_canceled},slurm_jobs_failed=${slurm_jobs_failed},slurm_last_cycle_time=${slurm_last_cycle_time},slurm_max_cycle_time=${slurm_max_cycle_time},slurm_total_cycles=${slurm_total_cycles},slurm_mean_cycle=${slurm_mean_cycle},slurm_mean_depth_cycle=${slurm_mean_depth_cycle},slurm_cycles_per_minute=${slurm_cycles_per_minute},slurm_last_queue_length=${slurm_last_queue_length},slurm_tot_backfill_jobs_from_start=${slurm_tot_backfill_jobs_from_start},slurm_tot_backfill_jobs_from_cycle=${slurm_tot_backfill_jobs_from_cycle},slurm_backfill_het_job_components=${slurm_backfill_het_job_components},slurm_total_cycles_backfill=${slurm_total_cycles_backfill},slurm_last_cycle_backfill=${slurm_last_cycle_backfill},slurm_max_cycle_backfill=${slurm_max_cycle_backfill},slurm_mean_cycle_backfill=${slurm_mean_cycle_backfill},slurm_last_depth_cycle_backfill=${slurm_last_depth_cycle_backfill},slurm_last_depth_cycle_try_backfill=${slurm_last_depth_cycle_try_backfill},slurm_depth_mean_backfill=${slurm_depth_mean_backfill},slurm_depth_mean_try_backfill=${slurm_depth_mean_try_backfill},slurm_last_queue_length_backfill=${slurm_last_queue_length_backfill},slurm_queue_length_mean_backfill=${slurm_queue_length_mean_backfill},slurm_last_table_size_backfill=${slurm_last_table_size_backfill},slurm_last_mean_table_size_backfill=${slurm_last_mean_table_size_backfill}"
else
        IFS=" " read slurm_tot_backfill_jobs_from_start slurm_tot_backfill_jobs_from_cycle slurm_backfill_het_job_components slurm_total_cycles_backfill slurm_last_cycle_backfill slurm_max_cycle_backfill slurm_last_depth_cycle_backfill slurm_last_depth_cycle_try_backfill slurm_last_queue_length_backfill slurm_last_table_size_backfill  <<< "$(cat ${tf} | grep -A 11 "Backfilling stats" | tail -n +2 | grep -v "Last cycle when" | cut -d':' -f 2- | sed -e 's/^[[:space:]]*//' | xargs)"

        echo "slurm_scheduler_data slurm_server_thread_count=${slurm_server_thread_count},slurm_agent_queue_size=${slurm_agent_queue_size},slurm_agent_count=${slurm_agent_count},slurm_agent_thread_count=${slurm_agent_thread_count},slurm_dbd_agent_queue_size=${slurm_dbd_agent_queue_size},slurm_jobs_submitted=${slurm_jobs_submitted},slurm_jobs_started=${slurm_jobs_started},slurm_jobs_completed=${slurm_jobs_completed},slurm_jobs_canceled=${slurm_jobs_canceled},slurm_jobs_failed=${slurm_jobs_failed},slurm_last_cycle_time=${slurm_last_cycle_time},slurm_max_cycle_time=${slurm_max_cycle_time},slurm_total_cycles=${slurm_total_cycles},slurm_mean_cycle=${slurm_mean_cycle},slurm_mean_depth_cycle=${slurm_mean_depth_cycle},slurm_cycles_per_minute=${slurm_cycles_per_minute},slurm_last_queue_length=${slurm_last_queue_length},slurm_tot_backfill_jobs_from_start=${slurm_tot_backfill_jobs_from_start},slurm_tot_backfill_jobs_from_cycle=${slurm_tot_backfill_jobs_from_cycle},slurm_backfill_het_job_components=${slurm_backfill_het_job_components},slurm_total_cycles_backfill=${slurm_total_cycles_backfill},slurm_last_cycle_backfill=${slurm_last_cycle_backfill},slurm_max_cycle_backfill=${slurm_max_cycle_backfill},slurm_last_depth_cycle_backfill=${slurm_last_depth_cycle_backfill},slurm_last_depth_cycle_try_backfill=${slurm_last_depth_cycle_try_backfill},slurm_last_queue_length_backfill=${slurm_last_queue_length_backfill},slurm_last_table_size_backfill=${slurm_last_table_size_backfill}"
fi

rm -rf ${tfile1} ${tfile2} ${tfile3}
