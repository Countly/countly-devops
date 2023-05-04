MONGODB_SERVICE_FILE=$(systemctl status mongod|grep loaded|awk -F'(' '{print $2}'|awk -F';' '{print $1}')
MONGODB_USER=$(grep 'User=' "${MONGODB_SERVICE_FILE}"|awk -F'=' '{print $2}')

printf "o\nn\np\n1\n\n\nw\n" | sudo fdisk /dev/sdb

mkfs.xfs /dev/sdb1
mkdir /data
mount /dev/sdb1 /data
chown -R ${MONGODB_USER}:${MONGODB_USER} /data

sed -i 's#\/var\/lib\/mongodb#\/data#g' /etc/mongod.conf
systemctl restart mongod
echo "/dev/sdb1 /data xfs defaults,noatime,nodiratime 0 0" | sudo tee --append /etc/fstab

sleep 3
