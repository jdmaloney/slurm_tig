# Slurm TIG
These exec scripts are used to ingest scheduler, partition, job metrics from a Slurm cluster.  One can run any or all or some combination of these checks, though running all of them of course gives the most detailed information.  Descriptions of the scripts are below along with implementation details for each.  

## Slurm Scheduler
This check provides basic partition stats as well as stats about the scheduler itself and how well it is performing by capturing its internal metrics.  Implementation details:
- For telegraf (the user that'll execute this shell script) to see all jobs it needs to be in the admin group so it can see all jobs, or you can give the telgraf user sudo permission to run slurm commands and modify this script to invoke sudo on all scheduler commands.  It is recommended to just add Telegraf's user (by default "telegraf") to the admin group as that is simpler generally, cleaner, and a bit more safe.  

## Slurm Detail Stats
This check gathers data in more detail on a per partition basis, tracking the breakdown of cpu/memory/gpu utilization in a partition on a per user basis, as well as utilization down to the core, GB of memory, and GPU level.  Also it tracks pending jobs by state to help quickly see why jobs aren't running.  Same implementation detail applies to this check as the above; telegraf must in some way get to admin status so it can see all jobs in the queue.  

## Slurm Job Efficiency
This check records job efficiency data, tracking how efficient users and groups are (on a per-user/group, per-partition basis) with requesting cpu and memory resources.  In addition to capturing the cpu/memory efficiency for each job, it also captures the total core-clock time of the job and stores that in a field as well.  This allows for the weighting of results by core-hour, so user's are "penalized" for short debug runs that could skew results of their efficiency.  The dependencies for implementation are:
- The installation of the seff plugin for Slurm (https://github.com/SchedMD/slurm/blob/master/contribs/seff/seff), this needs to be in the slurm command path as well
- Credentials/DB Info about connecting to your slurmdbd is needed in the slurm_config file.  This allows the script to reach out and connect to it and pull in information
- By default this check is meant to be run every hour, and it will pull in data from completed jobs for the hour prior.  If you want to adjust the frequency of the data ingestion, make sure to also alter the SQL query.

## Slurm Accounting Stats (BETA)
This check pulls in historical job information resource utilization (core hours, gb_mem hours, and gpu hours) on a per user/charge account/partition basis and stores this in InfluxDB.  The check is meant to be run on an hourly basis to pull in metrics for jobs that completed their run in the hour prior. This check is in BETA as it currently is not set to map userids to "pretty" usernames, this feature will hopefully be landing soon.
