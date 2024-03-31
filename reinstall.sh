cd ~ || { echo "Couldn't get to home directory"; exit 1; }
mapfile -t files < <(sudo find . -maxdepth 5 -type d -name "*unchained*" -exec sudo find {} -type d -name "conf" -printf "%h\n" \;)

# Check if any files were found
if [ ${#files[@]} -eq 0 ]; then
    echo "Error: No unchained directory was found on home directory" "red"
    exit 1
fi

# Display options to the user
echo "Which is your current working directory of unchained node:"
select option in "${files[@]}"; do
    if [ -n "$option" ]; then
        old_directory="$option"
        break
    else
        echo "Invalid option. Please try again."
    fi
done

sudo wget https://github.com/KenshiTech/unchained/releases/download/v0.11.21/unchained-v0.11.21-docker.zip
sudo unzip unchained-v0.11.21-docker.zip || { echo "Couldn't unzip file"; exit 1; }
cd unchained-v0.11.21-docker
sudo docker rm --force unchained_worker
sudo ./unchained.sh worker up -d --force-recreate
sudo ./unchained.sh worker stop
sudo cp .$old_directory/conf/secrets.worker.yaml conf/secrets.worker.yaml
sudo wget -q https://raw.githubusercontent.com/KenshiTech/unchained/master/conf.worker.yaml.template -O conf/conf.worker.yaml
node_name=$(sudo cat .$old_directory/conf/conf.worker.yaml | grep name | head -n 1 | awk -F ': ' '{print $2}')
sudo sed -i "s/<name>/$node_name/g" conf/conf.worker.yaml
sudo ./unchained.sh worker restart
sudo ./unchained.sh worker logs -f