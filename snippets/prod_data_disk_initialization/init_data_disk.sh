MONGO_USER=$(grep mongo /etc/passwd | head -1 | awk -F':' '{print $1}')

printf "o\nn\np\n1\n\n\nw\n" | sudo fdisk /dev/sdb

mkfs.xfs /dev/sdb1
mkdir /data
mount /dev/sdb1 /data
chown -R ${MONGO_USER}:${MONGO_USER} /data

sed -i 's#\/var\/lib\/mongodb#\/data#g' /etc/mongod.conf
systemctl restart mongod
echo "/dev/sdb1 /data xfs defaults,noatime,nodiratime 0 0" | sudo tee --append /etc/fstab

sleep 3
