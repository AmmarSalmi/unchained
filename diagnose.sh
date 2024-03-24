#!/bin/bash

CONTAINER_NAME="unchained_worker"

#Welcome message and explanation
echo "##########################################################################"
echo "# Unchained Ironsmith                                                    #"
echo "# A community-made tool to help diagnose and fix unchained node problem. #"
echo "# v1.1 Supports only docker nodes and tested only on ubuntu              #"
echo "##########################################################################"

#Declaring functions here
#Colored output function
cecho() {
    case $2  in
    'green')
        echo -e "\e[32m$1\e[0m"
        ;;
    'yellow')
        echo -e "\e[33m$1\e[0m"
        ;;
    'red')
        echo -e "\e[31m$1\e[0m"
        ;;
    *)
        echo "$1"
        ;;
    esac
}
# A function to check if container is running
isRunning() {
    container_state=$(sudo docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME")
    echo "$container_state"
}

# A function to check if container is restarting
isRestarting() {
    sleep 3
    container_state=$(sudo docker inspect --format='{{.State.Restarting}}' "$CONTAINER_NAME")
    echo "$container_state"
}

get_logs_path() {
    container_logs=$(sudo docker inspect --format='{{.LogPath}}' "$CONTAINER_NAME")
    echo "$container_logs"
}

get_current_version()  {
    #check current version
    logs_path=$(get_logs_path)
    version=$(sudo cat "$logs_path" | grep 'Version' | tail -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 )
    echo "$version"
}

get_latest_version() {
    latest_version=$(curl -s "https://github.com/KenshiTech/unchained/releases" | grep 'releases/tag/v' | grep -iEv 'alpha|beta|rc'| head -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    echo "$latest_version"
}

is_uptodate() {
current_version="$(get_current_version)"
latest_version="$(get_latest_version)"
[ "$latest_version" == "$current_version" ] && echo "true" || echo "false"
}

is_latest_stable() {
    releases_url="https://github.com/KenshiTech/unchained/releases"
    release=$(curl -s $releases_url | grep 'releases/tag/v' | head -n 1 | grep -iE 'alpha|beta|rc')
    [ -z "$release" ] && echo 'true' || echo 'false'
}

pull_and_recreate() {
    cecho "Pulling latest image..." "yellow"
    update_response=$({ sudo ./unchained.sh worker pull; } 2>&1)
    cecho "Removing container..." "yellow"
    remove_container_response=$({ sudo docker rm --force unchained_worker;} 2>&1)
    cecho "Starting up the node..." "yellow"
    starting_response=$({ sudo ./unchained.sh up -d --force-recreate; } 2>&1)
    echo "update response: $update_response || remove container response:$remove_container_response || recreate response: $starting_response" 
}
#getting image id based on the tag provided in arg
get_imageID() {
    image_id=$(docker image ls --filter "reference=ghcr.io/kenshitech/unchained:$1")
    echo "$image_id"
}

#Trying to update the node without catching an alph/beta/rc release by mistake
safe_update() {
    if [ "$(is_latest_stable)" == "true" ]
    then
        #updating the node with regular "pull" and "up -d"
        cecho "Attempting to update with regular pull since latest image is a stable release" "yellow"
        response=$(pull_and_recreate)
        sleep 2
        update_state=$(is_uptodate)
        if [ "$update_state" == "true" ] 
        then
            cecho "Node was updated successfully with a regular pull" "green"
            return 1
        else
            cecho "Node update failed" "red"
            cecho "responses from update attempt:" "yellow"
            echo -e "$response"
            return 0
        fi
    else
        #dodging alpha release
        cecho "Latest image is not stable. Attempting to circumvent unstable release..." "yellow"
        #removing the image tagged as latest since it's not the latest stable release
        cecho "Removing latest image from your machine..." "yellow"
        sudo docker rmi --force ghcr.io/kenshitech/unchained:latest 1> /dev/null
        cecho "Pulling latest stable image..." "yellow"
        latest_stable=$(get_latest_version)
        sudo docker pull ghcr.io/kenshitech/unchained:v"$latest_stable" >/dev/null
        cecho "Tagging image as latest..." "yellow"
        sudo docker tag ghcr.io/kenshitech/unchained:v"$latest_stable" ghcr.io/kenshitech/unchained:latest >/dev/null
        cecho "Removing container..." "yellow"
        sudo docker rm --force unchained_worker >/dev/null
        cecho "Starting up a node with stable release image..." "yellow"
        sudo ./unchained.sh worker up -d > /dev/null 1>&2
        sleep 2
        update_state=$(is_uptodate)
        if [[ "$update_state" == "true" ]] 
        then
            cecho "Node was updated successfully to latest stable release" "green"
            return 1
        else
            echo "Node update failed"
            #cecho "responses from update attempt:" "yellow"
            #echo -e "$response"
            return 0
        fi
    fi

}

#Checking if docker version 2 is installed
if ! command -v docker &>/dev/null; then
  cecho "Error: docker could not be found on your system!" "red"
  echo "You can refer to this guide to install docker V2"
  echo "https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-20-04"
  exit 1
elif ! docker compose version 2>/dev/null | grep -qe '[ vV]2'; then
  cecho "Error: docker compose v2 could not be found on your system!" "red"
  echo "You can refer to this guide to install docker V2"
  echo "https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-20-04"
  exit 1
fi

cecho "Making sure docker service is running..."
if ! sudo docker ps -a &>/dev/null
then
    cecho "Docker service is not running" "red"
    cecho "Attempting to start docker service" "yellow"
    sudo snap start docker > /dev/null 2>&1
    sudo systemctl start docker > /dev/null 2>&1
    sleep 3
    if ! sudo docker ps -a > /dev/null 2>&1
    then
        cecho "Error: Can't start docker service" "red"
        exit 1
    else
        cecho "Docker service started successfully" "green"
    fi
else
    cecho "Docker service is up and running." "green"
fi


# Inspecting unchained container to grab the working directory
cecho "Attempting to auto-detect working directory of your node..." "yellow"
if ! sudo docker inspect "$CONTAINER_NAME" &> /dev/null; then
    cecho "Error: $CONTAINER_NAME container doesn't exist" "red"
    cecho "Attempting to locate unchained folder" "yellow"
    
    #navigating to home directory
    cd ~ || { echo "Error: Failed to change directory to the home directory."; exit 1; }
    
    # Store search results in an array
    files=($(sudo find  . -maxdepth 5 -type d -name "*unchained*" -exec sudo find {} -type f -name "unchained.sh" -printf "%h\n" \;))

    # Check if any files were found
    if [ ${#files[@]} -eq 0 ]; then
        cecho "Error: No unchained directory was found on home directory" "red"
        #curl -s "https://github.com/KenshiTech/unchained/releases" | grep 'releases/tag/v' | grep -o '<a [^>]*href="[^"]*"'| grep -Ev 'alpha|rc' | awk -F '"' '{print $2}'| sed 's#/KenshiTech/unchained/releases/tag/\(v[0-9]\+\.[0-9]\+\.[0-9]\+\)#https://github.com/KenshiTech/unchained/releases/download/\1/unchained-\1-docker.zip#'
        #sudo docker tag f9716ec5fb27 ghcr.io/kenshitech/unchained:latest
        exit 1
    fi

    # Display options to the user
    echo "Which is your working directory of unchained node:"
    select option in "${files[@]}"; do
        if [ -n "$option" ]; then
            cecho "Navigating to directory: $option" "yellow"
            cd "$option" ||  { echo "Error: Failed to change directory to $option."; exit 1; }
            cecho "Starting the node..." "yellow"
            sudo ./unchained.sh worker up -d > /dev/null 2>&1
            # Add your command to open the selected file here (e.g., open "$option")
            break
        else
            echo "Invalid option. Please try again."
        fi
    done

    fi

# Get the Docker inspect output
docker_inspect=$(sudo docker inspect --format='{{json .Config.Labels}}' "$CONTAINER_NAME")
# Extract the folder path using grep and awk
folder=$(echo "$docker_inspect" | grep -o '"com.docker.compose.project.working_dir":"[^"]*' | awk -F ':"' '{print $2}')

# Change directory to the folder where the Docker container was created
cd "$folder" ||  { echo "Error: Failed to change directory to $folder."; exit 1; }
cecho "Working directory detected $(pwd)" "green"



cecho "Checking if the node is running..." "yellow"
node_state=$(isRunning)
start_node_escalation=1
response=""
while [[ $node_state == "false" ]]
do
    cecho "The node is not running" "red"
    case $start_node_escalation in
        1)
            cecho "Starting the node attempt $start_node_escalation" "yellow"
            response=$( { sudo ./unchained.sh worker up -d; } 2>&1)
            node_state=$(isRunning)
            ((start_node_escalation++))
            ;;
        2)
            echo "Starting the node attempt $start_node_escalation"
            if echo "$response" | grep -q Conflict
            then
                echo "Removing conflicting container"
                response=$( { sudo docker rm --force $CONTAINER_NAME && sudo ./unchained.sh worker up -d; } 2>&1)
                node_state=$(isRunning)
            fi
            ((start_node_escalation++))
            ;;

        *)
            echo "Unknown problem while trying to run the node $response"
            exit 1
            ;;
    esac
done

if [[ $start_node_escalation -eq 1 ]]
then
    cecho "Node is running" "green"
else
    cecho "Node started successfully" "green"
fi
#Giving the node a time to run

#Check restarting status to determin if there is a problem with the node
cecho "Checking if the node keep restarting because of an error and if outdated" "yellow"
node_restarting=$(isRestarting)
node_uptodate=$(is_uptodate)
fix_node_escalation=1
response=""
while [[ $node_restarting == "true" ]] || [[ $node_uptodate == "false" ]]
do
    [[ $node_restarting == "true" ]] && cecho "Node keeps restarting" "yellow"
    [[ $node_uptodate == "false" ]] && cecho "Node is either outdated or using an unstable release" "yellow"
    case $fix_node_escalation in
        1)
            cecho "Fixing the error attempt $fix_node_escalation: updating conf file." "yellow"
            node_name=$(sudo cat conf/conf.worker.yaml | grep name: | head -n 1 | awk -F ': ' '{print $2}')
            if [ "$node_name" == '<name>' ]
            then
                read -r -p "Please, enter your perfered node name: " node_name
            fi
            cecho "Setting your node name to $node_name"
            wget -q https://raw.githubusercontent.com/KenshiTech/unchained/master/conf.worker.yaml.template -O conf.yaml 
            sed -i "s/<name>/$node_name/g" conf.yaml
            sudo mv conf.yaml conf/conf.worker.yaml
            sudo ./unchained.sh worker restart 2>/dev/null
            ((fix_node_escalation++))
            node_restarting=$(isRestarting)
            node_uptodate=$(is_uptodate)
            ;;
        2)
            cecho "Fixing the error attempt $fix_node_escalation: updating the node." "yellow"
            safe_update
            ((fix_node_escalation++))
            node_restarting=$(isRestarting)
            node_uptodate=$(is_uptodate)
            ;;
        *)
            cecho "Unknown error" "red"
            exit 1
            ;;
    esac
done
node_name=$(sudo cat conf/conf.worker.yaml | grep name: | head -n 1 | awk -F ': ' '{print $2}')
unchained_address=$(sudo cat conf/secrets.worker.yaml | grep address | head -n 1 | awk -F ': ' '{print $2}')
cecho "Node has been repaired."
echo "Please check if your score is increasing on the leadboard. Visit https://kenshi.io/unchained."
echo "Your node name is $node_name and your address is $unchained_address"
echo "For further help please visit us at https://t.me/KenshiTech. Find us in Unchained channel."
