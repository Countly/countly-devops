For future reference, all Synchronoss machines have 30 day TTLs and a daily cronjob.

0 0 * * * /bin/bash /home/countly/expireData.cron.sh

expireData.cron.sh:

mongo < /home/countly/expireData.js > /home/countly/expire.log
date >> /home/countly/expire.log