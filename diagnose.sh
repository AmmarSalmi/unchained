#!/bin/bash
#Constants
#the docker image name for unchained worker
CONTAINER_NAME="unchained_worker"
#default value for timeout when monitoring points increase on leadboard
POINTS_TIMEOUT=15

#Welcome message and explanation
echo "#################################################################################"
echo "# Unchained Ironsmith                                                           #"
echo "# A community-made tool to help diagnose and fix unchained node problem.        #"
echo "# v1.2 Supports only docker nodes and tested only on ubuntu, debian, and centos #"
echo "#################################################################################"

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

#TO-DO merge both isRunning and isRestarting in one check_state function
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

#Get the file path for the logs of the node
#Better source to catch useful information
#Using ./unchained.sh worker logs -f is dynamic and could be troublesome
get_logs_path() {
    container_logs=$(sudo docker inspect --format='{{.LogPath}}' "$CONTAINER_NAME")
    echo "$container_logs"
}

#Check the node logs for the currently used unchained version
get_current_version()  {
    #check current version
    logs_path=$(get_logs_path)
    version=$(sudo cat "$logs_path" | grep 'Version' | tail -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 )
    echo "$version"
}

#Get the latest stable release from release page on github
#TO-DO It's hard-coded and might need more finess to able to adapt in possible pages in the web page
get_latest_version() {
    latest_version=$(curl -s "https://github.com/KenshiTech/unchained/releases" | grep 'releases/tag/v' | grep -iEv 'alpha|beta|rc'| head -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    echo "$latest_version"
}

#Compare the current version of the node to the latest stable release
is_uptodate() {
current_version="$(get_current_version)"
latest_version="$(get_latest_version)"
[ "$latest_version" == "$current_version" ] && echo "true" || echo "false"
}

#Check the release page if the most recent push is stable or alpha, beta, rc
is_latest_stable() {
    releases_url="https://github.com/KenshiTech/unchained/releases"
    release=$(curl -s $releases_url | grep 'releases/tag/v' | head -n 1 | grep -iE 'alpha|beta|rc')
    [ -z "$release" ] && echo 'true' || echo 'false'
}

#Simple pull and "up -d" sequence
pull_and_recreate() {
    cecho "Pulling latest image..." "yellow"
    update_response=$({ sudo ./unchained.sh worker pull; } 2>&1)
    cecho "Removing container..." "yellow"
    remove_container_response=$({ sudo docker rm --force unchained_worker;} 2>&1)
    cecho "Starting up the node..." "yellow"
    starting_response=$({ sudo ./unchained.sh up -d --force-recreate; } 2>&1)
    echo "update response: $update_response || remove container response:$remove_container_response || recreate response: $starting_response" 
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

#Get the current node public key
get_publickey() {
sudo cat conf/secrets.worker.yaml | grep public | awk -F ': ' '{print $2}'
}

#Use API to fetch the node points on the scoreboard
get_points() {
    command -v base58 &>/dev/null || { sudo "$PKG_MNGR" install base58 -y &>/dev/null; }
    command -v jq &>/dev/null || { sudo "$PKG_MNGR" install jq -y &>/dev/null; }

    #base58_key="$1"

    # Decode Base58 string to binary using base58 command
    #base58_decoded=$(echo "$base58_key" | base58 -d)

    # Convert trimmed binary string to hexadecimal using xxd command
    #hex_key=$(echo -n "$base58_decoded" | xxd -p | tr -d '\n')
    hex_key="$1"
    # Construct the GraphQL query with the hex key variable
    query="{ \"query\": \"query Signers { signers (where: {key: \\\"$hex_key\\\"}) { edges { node { name points } } } }\" }"

    # Make the curl POST request with the constructed JSON data
    json_data=$(curl -sX POST \
    -H "Content-Type: application/json" \
    -d "$query" \
    https://shinobi.brokers.kenshi.io/gql/query)

    # Extract the points from the JSON data using jq
    points=$(echo "$json_data" | jq -r '.data.signers.edges[0].node.points')

    # Print the extracted values
    echo "$points"
}
monitor_score()  {
    publicKey="${1:-"$pubkey"}"
    local timeout=${2:-$POINTS_TIMEOUT}
    current_score="$(get_points "$publicKey")";
    points_0=$((current_score));
    updated_points="$current_score";
    points_1=$((updated_points));
    #echo -n "Monitoring score to detect change. Please wait.";
    waiting_time=0;
    TIME_INCREMENT=3;
    while (( points_1 == points_0 )) && (( waiting_time < timeout ));
    do
        sleep "$TIME_INCREMENT";
        updated_points="$(get_points "$publicKey")";
        points_1=$((updated_points));
        ((waiting_time += $((TIME_INCREMENT)) ));
        #echo -n ".";
    done
    #cecho " done" "green";
    gained_points=$((points_1 - points_0));
    echo "$gained_points"
    }

#Just a function to make sure that all nodes are not getting points for some global error
is_broker_down() {
    public_keys=(
    #ammarubuntu node
    "qTs5AQ1985W3scp3rNDdu97YhUt6sLVN3uyxD9GU4siQj3MwmVBX9DLW9hqgwXR5AYGpSen9juvbcZUUkoUjMh8YY17wd5nBa45u7YP3d57AiqXWuVf1hw6FSrFxjuk17zW"
    #ammardebian node
    "tj2PBQ32LKNMqWq9nWBJiGP1cmU2r5njasF4bzS3vW79NpCBUV9SVpDd2DGr6gxoyWQVjkLFeuL8RHqrDP2sk7fCV6RGPir9g8dvTrNbWcu8puZN3FnXPAeX15tbwGASW3u"
    #jay's node
    "mR95NEFnVPuiNXRoBfmRHipTAJGWdz2q34KfwjHVp6ngn98P9DbrZUsA11WPQ6eMiRdUav8gSDYJRiGLBbE5ShnPzrVKnbjyULfY3ZAUTPSZSfQoLzRNocrgjnEGXitRpE8"
    )
    tested_nodes=0
    for key in "${public_keys[@]}"
    do
        [[ $(($(monitor_score "$key" 15))) -gt 0 ]] && break
        ((tested_nodes++))
    done
    [ "$tested_nodes" -eq "${#public_keys[@]}" ]
}

#Detect linux dist and set the appropriate package manager
#Some commands like wget, jq, base58 may not be installed by default on some machines
#They are needed for this script to run properly
if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" = "ubuntu" ] || [ "$ID" = "debian" ]; then
            PKG_MNGR="apt"
        elif [ "$ID" = "centos" ]; then
            PKG_MNGR="yum"
        else
            echo "Unsupported Linux distribution."
            exit 1
        fi
else
        echo "Could not determine Linux distribution."
        exit 1
fi

echo "$ID linux distro detected. Package manager set to $PKG_MNGR." 

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
    mapfile -t files < <(sudo find . -maxdepth 5 -type d -name "*unchained*" -exec sudo find {} -type f -name "unchained.sh" -printf "%h\n" \;)

    # Check if any files were found
    if [ ${#files[@]} -eq 0 ]; then
        cecho "Error: No unchained directory was found on home directory" "red"
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
            #TO-DO detecting generic node names with regex
            node_name=$(sudo cat conf/conf.worker.yaml | grep name: | head -n 1 | awk -F ': ' '{print $2}')
            if [ "$node_name" == '<name>' ] || [[ "$node_name" =~ [a-zA-Z]+-[a-zA-Z]+-[a-zA-Z]+ ]]
            then
                    echo "Generic name detected: $node_name."
                    read -r -p "Please, enter your perfered node name or press ENTER to keep the same name: "
            fi
            #Increasing timeout if name changed since detecting points take longer if name is changed
            [ -z "$REPLY" ] && new_node_name="$node_name" || { new_node_name="$REPLY"; POINTS_TIMEOUT=60; }
            echo "Setting your node name to $new_node_name"
            #make sure wget is on the system
            ! command -v wget &>/dev/null && sudo "$PKG_MNGR" install wget -y &>/dev/null
            wget -q https://raw.githubusercontent.com/KenshiTech/unchained/master/conf.worker.yaml.template -O conf.yaml 
            sed -i "s/<name>/$new_node_name/g" conf.yaml
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
cecho "Node has been repaired." "green"
pubkey="$(get_publickey)"
current_score="$(get_points "$pubkey" )"
echo -n "Your node name is "
cecho "${node_name}." "green"
echo -n "Your address is "
cecho "${unchained_address}." "green"
echo -n "Your current score on the leadboard is "
cecho "${current_score}." "green"
echo "If your score should be higher then this."
echo "Make sure you're using the right secret key in your secrets.worker.yaml file"
echo "which resides in conf folder."
cecho "Let's make sure your node is gaining points. Please wait..." "yellow"
gained_points=$(("$(monitor_score)"))
if [[ gained_points -ne 0 ]] 
then
    cecho "Your node is currently gaining points." "green" 
else
    cecho "Your node didn't gain any points for $POINTS_TIMEOUT seconds." "red";
    cecho "Checking if the problem is with the brokers not with your node..." "yellow"
    if  is_broker_down 
    then
        cecho  "Brokers are possibly down.The problem is not on your part." "green" 
    else
        cecho "Other nodes are gaining points. The problem is on your part." "red" 
    fi
fi
echo "For further help, please visit us at https://t.me/KenshiTech. Find us in Unchained channel."