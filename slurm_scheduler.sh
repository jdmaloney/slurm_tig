#!/bin/bash

## High Level Slurm Metrics
## Can run on any host that can query the scheduler
## Put telegraf in admin group so it can see all queues; or add telegraf to sudoers and modify script to execute slurm commands with sudo

slurm_path="/usr/slurm/bin"
partitions=($("${slurm_path}"/sinfo -h | awk '{print $1}' | sort -u | xargs | sed 's/*//g'))

## Get data
tf=$(mktemp /tmp/slurm1.XXXXXX)
qf=$(mktemp /tmp/slurm2.XXXXXX)
"${slurm_path}"/squeue -a -h -l > $tf
"${slurm_path}"/squeue -h -l -O Partition,Username,State > $qf


##Aggregate Node Stats
IFS="/" read nodes_busy nodes_idle nodes_offline nodes_total <<< "$("${slurm_path}"/sinfo -h -o %F)"

echo "slurm_nodesumdata,partition=all,type=busy count=${nodes_busy}"
echo "slurm_nodesumdata,partition=all,type=idle count=${nodes_idle}"
echo "slurm_nodesumdata,partition=all,type=offline count=${nodes_offline}"
echo "slurm_nodesumdata,partition=all,type=total count=${nodes_total}"

total_jobs=$(cat $tf | wc -l)
running_jobs=$(cat $tf | grep RUNNING | wc -l )
pending_jobs=$(cat $tf | grep PENDING | wc -l )

echo "slurm_jobsumdata,partition=all,type=running count=${running_jobs}"
echo "slurm_jobsumdata,partition=all,type=pending count=${pending_jobs}"
echo "slurm_jobsumdata,partition=all,type=total count=${total_jobs}"

pend_line="slurm_jobsumdata,partition=all,type=pendingbyreason "
found_pending=0
while IFS= read -r line; do
        found_pending=1
        IFS=" " read -r pend_job_count pend_reason <<< "${line}"
        pend_line="${pend_line},${pend_reason}=${pend_job_count}"
done < <(awk '{print $9}' ${tf} | awk '$1 ~ /\(/ {print $0}' | sort | uniq -c | sed 's/^ *//g' | tr -d '()' | sed 's/,//g')
if [ ${found_pending} -eq 1 ]; then
        final_pend_line=$(echo ${pend_line} | sed 's/\ ,/\ /')
        echo "${final_pend_line}"
fi

for p in ${partitions[@]}
do
	total_jobs=$(cat $qf | awk -v p="$p" '$1==p {print $0}' | wc -l)
	running_jobs=$(cat $qf | awk -v p="$p" '$1==p {print $0}' | awk '$3 == "RUNNING" {print $0}' | wc -l )
	pending_jobs=$(cat $qf | awk -v p="$p" '$1==p {print $0}' | awk '$3 == "PENDING" {print $0}' | wc -l )

	echo "slurm_jobsumdata,partition=$p,type=running count=${running_jobs}"
	echo "slurm_jobsumdata,partition=$p,type=pending count=${pending_jobs}"
	echo "slurm_jobsumdata,partition=$p,type=total count=${total_jobs}"

	pend_line="slurm_jobsumdata,partition=${p},type=pendingbyreason "
        found_pending=0
        while IFS= read -r line; do
                found_pending=1
                IFS=" " read -r pend_job_count pend_reason <<< "${line}"
                pend_line="${pend_line},${pend_reason}=${pend_job_count}"
        done < <(awk -v partition=${p} '$2 == partition {print $9}' ${tf} | awk '$1 ~ /\(/ {print $0}' | sort | uniq -c | sed 's/^ *//g' | tr -d '()' | sed 's/,//g')
        if [ ${found_pending} -eq 1 ]; then
                final_pend_line=$(echo ${pend_line} | sed 's/\ ,/\ /')
                echo "${final_pend_line}"
        fi

	IFS="/" read alloc_nodes idle_nodes offline_nodes total_nodes <<< "$("${slurm_path}"/sinfo -h --partition="$p" -o %F)"

	if [ -z "${alloc_nodes}" ]; then
		precent_offline=0
		offline_nodes=0
		alloc_nodes=0
		idle_nodes=0
		total_nodes=0

		echo "slurm_nodedata,partition=$p,type=offline count=${offline_nodes}"
                echo "slurm_nodedata,partition=$p,type=busy count=${alloc_nodes}"
                echo "slurm_nodedata,partition=$p,type=idle count=${idle_nodes}"
                echo "slurm_nodedata,partition=$p,type=total count=${total_nodes}"
                echo "slurm_nodedata,partition=$p,type=percent_offline percent=${percent_offline}"
	else
		percent_offline=$(echo "${offline_nodes} / ${total_nodes} * 100" | bc -l)

		echo "slurm_nodedata,partition=$p,type=offline count=${offline_nodes}"
	        echo "slurm_nodedata,partition=$p,type=busy count=${alloc_nodes}"
		echo "slurm_nodedata,partition=$p,type=idle count=${idle_nodes}"
		echo "slurm_nodedata,partition=$p,type=total count=${total_nodes}"
		echo "slurm_nodedata,partition=$p,type=percent_offline percent=${percent_offline}"
	fi

	users=($(cat $qf | awk '{print $2}' | sort -u))
	for u in ${users[@]}
	do
		count_running=$(cat $qf | awk -v u="$u" '$2==u {print $0}' | awk -v p="$p" '$1==p {print $0}' | awk '$3 == "RUNNING"' |  wc -l)
		count_pending=$(cat $qf | awk -v u="$u" '$2==u {print $0}' | awk -v p="$p" '$1==p {print $0}' | awk '$3 == "PENDING"' | wc -l)
		if [ $count_running -ne 0 ]; then
			echo "slurm_userjobdata,partition=$p,type=running,uname=$u count=$count_running"
		fi
		if [ $count_pending -ne 0 ]; then
                        echo "slurm_userjobdata,partition=$p,type=pending,uname=$u count=$count_pending"
                fi
	done

done

## Backfill & Scheduler Stats
"${slurm_path}"/sdiag > $tf

IFS=" " read slurm_server_thread_count slurm_agent_queue_size slurm_agent_count slurm_agent_thread_count slurm_dbd_agent_queue_size slurm_jobs_submitted slurm_jobs_started slurm_jobs_completed slurm_jobs_canceled slurm_jobs_failed <<< "$(cat $tf | grep -A 12 "Data since" | tail -n +3 | cut -d':' -f 2 | sed -e 's/^[[:space:]]*//' | xargs)"

IFS=" " read slurm_last_cycle_time slurm_max_cycle_time slurm_total_cycles slurm_mean_cycle slurm_mean_depth_cycle slurm_cycles_per_minute slurm_last_queue_length <<< "$(cat ${tf} | grep -A 7 "Main schedule statistics" | tail -n +2 | cut -d':' -f 2 | sed -e 's/^[[:space:]]*//' | xargs)"

if [ $(${slurm_path}/squeue -t pending | wc -l) -lt 2 ]; then
	IFS=" " read slurm_tot_backfill_jobs_from_start slurm_tot_backfill_jobs_from_cycle slurm_backfill_het_job_components slurm_total_cycles_backfill slurm_last_cycle_backfill slurm_max_cycle_backfill slurm_last_depth_cycle_backfill slurm_last_depth_cycle_try_backfill slurm_last_queue_length_backfill slurm_last_table_size_backfill <<< "$(cat ${tf} | grep -A 11 "Backfilling stats" | tail -n +2 | grep -v "Last cycle when" | cut -d':' -f 2- | sed -e 's/^[[:space:]]*//' | xargs)"

	echo "slurm_scheduler_data slurm_server_thread_count=${slurm_server_thread_count},slurm_agent_queue_size=${slurm_agent_queue_size},slurm_agent_count=${slurm_agent_count},slurm_agent_thread_count=${slurm_agent_thread_count},slurm_dbd_agent_queue_size=${slurm_dbd_agent_queue_size},slurm_jobs_submitted=${slurm_jobs_submitted},slurm_jobs_started=${slurm_jobs_started},slurm_jobs_completed=${slurm_jobs_completed},slurm_jobs_canceled=${slurm_jobs_canceled},slurm_jobs_failed=${slurm_jobs_failed},slurm_last_cycle_time=${slurm_last_cycle_time},slurm_max_cycle_time=${slurm_max_cycle_time},slurm_total_cycles=${slurm_total_cycles},slurm_mean_cycle=${slurm_mean_cycle},slurm_mean_depth_cycle=${slurm_mean_depth_cycle},slurm_cycles_per_minute=${slurm_cycles_per_minute},slurm_last_queue_length=${slurm_last_queue_length},slurm_tot_backfill_jobs_from_start=${slurm_tot_backfill_jobs_from_start},slurm_tot_backfill_jobs_from_cycle=${slurm_tot_backfill_jobs_from_cycle},slurm_backfill_het_job_components=${slurm_backfill_het_job_components},slurm_total_cycles_backfill=${slurm_total_cycles_backfill},slurm_last_cycle_backfill=${slurm_last_cycle_backfill},slurm_max_cycle_backfill=${slurm_max_cycle_backfill},slurm_mean_cycle_backfill=0,slurm_last_depth_cycle_backfill=${slurm_last_depth_cycle_backfill},slurm_last_depth_cycle_try_backfill=${slurm_last_depth_cycle_try_backfill},slurm_depth_mean_backfill=0,slurm_depth_mean_try_backfill=0,slurm_last_queue_length_backfill=${slurm_last_queue_length_backfill},slurm_queue_length_mean_backfill=0,slurm_last_table_size_backfill=${slurm_last_table_size_backfill},slurm_last_mean_table_size_backfill=0"
else
	IFS=" " read slurm_tot_backfill_jobs_from_start slurm_tot_backfill_jobs_from_cycle slurm_backfill_het_job_components slurm_total_cycles_backfill slurm_last_cycle_backfill slurm_max_cycle_backfill slurm_mean_cycle_backfill slurm_last_depth_cycle_backfill slurm_last_depth_cycle_try_backfill slurm_depth_mean_backfill slurm_depth_mean_try_backfill slurm_last_queue_length_backfill slurm_queue_length_mean_backfill slurm_last_table_size_backfill slurm_last_mean_table_size_backfill <<< "$(cat ${tf} | grep -A 16 "Backfilling stats" | tail -n +2 | grep -v "Last cycle when" | cut -d':' -f 2- | sed -e 's/^[[:space:]]*//' | xargs)"

	echo "slurm_scheduler_data slurm_server_thread_count=${slurm_server_thread_count},slurm_agent_queue_size=${slurm_agent_queue_size},slurm_agent_count=${slurm_agent_count},slurm_agent_thread_count=${slurm_agent_thread_count},slurm_dbd_agent_queue_size=${slurm_dbd_agent_queue_size},slurm_jobs_submitted=${slurm_jobs_submitted},slurm_jobs_started=${slurm_jobs_started},slurm_jobs_completed=${slurm_jobs_completed},slurm_jobs_canceled=${slurm_jobs_canceled},slurm_jobs_failed=${slurm_jobs_failed},slurm_last_cycle_time=${slurm_last_cycle_time},slurm_max_cycle_time=${slurm_max_cycle_time},slurm_total_cycles=${slurm_total_cycles},slurm_mean_cycle=${slurm_mean_cycle},slurm_mean_depth_cycle=${slurm_mean_depth_cycle},slurm_cycles_per_minute=${slurm_cycles_per_minute},slurm_last_queue_length=${slurm_last_queue_length},slurm_tot_backfill_jobs_from_start=${slurm_tot_backfill_jobs_from_start},slurm_tot_backfill_jobs_from_cycle=${slurm_tot_backfill_jobs_from_cycle},slurm_backfill_het_job_components=${slurm_backfill_het_job_components},slurm_total_cycles_backfill=${slurm_total_cycles_backfill},slurm_last_cycle_backfill=${slurm_last_cycle_backfill},slurm_max_cycle_backfill=${slurm_max_cycle_backfill},slurm_mean_cycle_backfill=${slurm_mean_cycle_backfill},slurm_last_depth_cycle_backfill=${slurm_last_depth_cycle_backfill},slurm_last_depth_cycle_try_backfill=${slurm_last_depth_cycle_try_backfill},slurm_depth_mean_backfill=${slurm_depth_mean_backfill},slurm_depth_mean_try_backfill=${slurm_depth_mean_try_backfill},slurm_last_queue_length_backfill=${slurm_last_queue_length_backfill},slurm_queue_length_mean_backfill=${slurm_queue_length_mean_backfill},slurm_last_table_size_backfill=${slurm_last_table_size_backfill},slurm_last_mean_table_size_backfill=${slurm_last_mean_table_size_backfill}"
fi

rm -rf ${tf} ${qf}
