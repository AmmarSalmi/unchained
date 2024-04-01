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
echo "# v1.3 Supports only docker nodes and tested only on ubuntu, debian, and centos #"
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

#Using inspect to check docker container various states
function check_container_state()
{
    #lowercase the argument
    state_label=${1,,}
    case $state_label in
        run|running)
            container_state=$(sudo docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME")
            [ "$container_state" == "true" ]
            ;;
        rest|restarting)
            #Docker often needs time to set .Restarting to true when node is restarting
            sleep 3 
            container_state=$(sudo docker inspect --format='{{.State.Restarting}}' "$CONTAINER_NAME")
            [ "$container_state" == "true" ]
            ;;
        *)
            echo "check_container_state function doesn't recognize the queried lable"
            return 1
            ;;
    esac
}

#TO-DO merge both isRunning and isRestarting in one check_state function
# A function to check if container is running
show_secretkey() {
    [ -f conf/secrets.worker.yaml ] && secretkey=$(sudo cat conf/secrets.worker.yaml | grep secret | awk -F ': ' '{print $2}') || echo "Can't find secrets.worker.yaml"
    first10chars=${secretkey: 0:10}
    last10chars=${secretkey: -10}
    echo "$first10chars**********$last10chars"
}

is_running() {
    check_container_state "running"
}

# A function to check if container is restarting
is_restarting() {
    check_container_state "restarting"
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
[[ "$latest_version" == "$current_version" ]]
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
    sudo docker ps | grep -q unchained_worker  && remove_container_response=$({ sudo docker rm --force unchained_worker;} 2>&1)
    cecho "Starting up the node..." "yellow"
    starting_response=$({ sudo ./unchained.sh worker up -d --force-recreate; } 2>&1)
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
        if is_uptodate 
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
        if  is_uptodate  
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
    command -v jq &>/dev/null || { sudo "$PKG_MNGR" install jq -y &>/dev/null; }
    command -v curl &>/dev/null || { sudo "$PKG_MNGR" install curl -y &>/dev/null; }
    
    hex_key="${1:-$PUBKEY}"
    
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
is_gaining_points()  {
    publicKey="${1:-$PUBKEY}"
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
    [[ $(($gained_points)) > 0 ]]
    }

#Just a function to make sure that all nodes are not getting points for some global error
is_broker_down() {
    public_keys=(
    #ammarubuntu node
    "8cafe3f3630e8a49bfc6fae1a3d4bd5db38458e34b781886f75cb8f25296416763a9e9feb1ef7da041238edcdbdaa63412445eb9030d2c9f58bbda0f7397a7cfeaf1fdf671de8dd7c42ca1010bf4d452d0d4889cb94439d004dd76a148d9a60f"
    #ammardebian node
    "96279fd86b29c018126f8be1c072095cbc2fc35f3933da38ce12e21c56e2e217f4735c4bf170675c0dd10b844e1b8ff6185b932214b266d3c5a6fb6901016db1a67d34606e6da75f6008126004279637f499c27cfe2bd691b12bf16c9fe8f714"
    #jay's node
    "80f0588b01cf7e2b1dae235c5a625ecf9d1c2b3d32eafe729fc9d551f1ef151a4fb30697344b05986ac565a7a29863b701091994bd3d18a43ad7a055bac555d7194d7556b90e278d5d624a801ee73980ac2131523bdc01894373eccba88af925"
    )
    tested_nodes=0
    for key in "${public_keys[@]}"
    do
        is_gaining_points "$key" 15  && break
        ((tested_nodes++))
    done
    [ "$tested_nodes" -eq "${#public_keys[@]}" ]
}

#Detect linux dist and set the appropriate package manager
#Some commands like wget, jq may not be installed by default on some machines
#They are needed for this script to run properly
if command -v apt &>/dev/null; then
    PKG_MNGR="apt"
elif command -v yum &>/dev/null; then
    PKG_MNGR="apt"
elif command -v dnf &>/dev/null; then
    PKG_MNGR="apt"
elif command -v pacman &>/dev/null; then
    PKG_MNGR="apt"
else
    echo "Unknown package manager"
    read -p -r "Please type your package manager: " pm_answer
    if [ ! -z "$pm_answer" ] && command -v "pm_answer" &>/dev/null; then
        PKG_MNGR="$pm_answer"
        cecho "WARNING: IronSmith wasn't tested with this package manager." "yellow"
    else
        echo "The package manager you typed doesn't exist on your system"
        exit 1
    fi
fi

echo "Package manager set to $PKG_MNGR." 

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


#Detecting the working directory of unchained node
cecho "Attempting to auto-detect working directory of your node..." "yellow"
folder=""
if ! sudo docker inspect "$CONTAINER_NAME" &> /dev/null
then
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
            folder="$option"
            break
        else
            echo "Invalid option. Please try again."
        fi
    done
else
    # Inspecting unchained container to grab the working directory
    # Get the Docker inspect output
    docker_inspect=$(sudo docker inspect --format='{{json .Config.Labels}}' "$CONTAINER_NAME")
    # Extract the folder path using grep and awk
    folder=$(echo "$docker_inspect" | grep -o '"com.docker.compose.project.working_dir":"[^"]*' | awk -F ':"' '{print $2}')

fi

# Change directory to the folder where the Docker container was created
echo "$folder"
if [ ! -z "$folder" ]
then
    cecho "Working directory detected $(pwd)" "green"
    cecho "Navigating to directory: $option" "yellow"
    cd "$folder" ||  { echo "Error: Failed to change directory to $folder."; exit 1; }
    cecho "Starting the node... $(pwd)" "yellow"
    #sudo ./unchained.sh worker up -d --force-recreate &> /dev/null
else
    cecho "Unable to detect working directory of unchained node" "red"
    exit 1
fi


cecho "Checking if the node is running..." "yellow"
start_node_escalation=1
response=""
while ! is_running
do
    cecho "The node is not running" "red"
    case $start_node_escalation in
        #TO-DO these towo cases needs to be converted to one nested IF
        1)
            cecho "Starting the node attempt $start_node_escalation" "yellow"
            if ! sudo ./unchained.sh worker up -d --force-recreate &> /dev/null
            then
                echo "Removing possible conflicting container"
                response="$( { sudo docker rm --force $CONTAINER_NAME && sudo ./unchained.sh worker up -d --force-recreate; } 2>&1)"
            fi
            ((start_node_escalation++))
            ;;
        *)
            cecho "Unknown problem while trying to run the node:" "red"
            echo "$response"
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

#Check restarting status to determin if there is a problem with the node
cecho "Checking if the node keep restarting because of an error and if outdated" "yellow"
fix_node_escalation=1
response=""
while is_restarting || ! is_uptodate
do
    is_restarting && cecho "Node keeps restarting" "yellow"
    ! is_uptodate && cecho "Node is either outdated or using an unstable release" "yellow"
    case $fix_node_escalation in
        1)
            cecho "Fixing the error attempt $fix_node_escalation: updating conf file." "yellow"
            #DONE: detecting generic node names with regex
            node_name=$(sudo cat conf/conf.worker.yaml | grep name: | head -n 1 | awk -F ': ' '{print $2}')
            if [ -z "$nodename" ] || [ "$node_name" == '<name>' ] || [[ "$node_name" =~ [a-zA-Z]+-[a-zA-Z]+-[a-zA-Z]+ ]]
            then
                    echo "Generic or null name detected: $node_name."
                    read -r -p "Please, enter your perfered node name or press ENTER to keep the same name: " answer
            fi
            #Increasing timeout if name changed since detecting points take longer if name is changed
            [ -z "$answer" ] && new_node_name="$node_name" || { new_node_name="$answer"; POINTS_TIMEOUT=60; }
            echo "Setting your node name to $new_node_name"
            node_name=$new_node_name
            #make sure wget is on the system
            #TO-DO use a variable for install keyword so you take care of special case of PACMAN manager
            ! command -v wget &>/dev/null && sudo "$PKG_MNGR" install wget -y &>/dev/null
            sudo wget -q https://raw.githubusercontent.com/KenshiTech/unchained/master/conf.worker.yaml.template -O conf.yaml 
            sudo sed -i "s/<name>/$new_node_name/g" conf.yaml
            sudo mv conf.yaml conf/conf.worker.yaml
            sudo ./unchained.sh worker restart 2>/dev/null
            ((fix_node_escalation++))
            ;;
        2)
            cecho "Fixing the error attempt $fix_node_escalation: updating the node." "yellow"
            safe_update
            ((fix_node_escalation++))
            ;;
        *)
            cecho "Unknown error" "red"
            exit 1
            ;;
    esac
done
unchained_address=$(sudo cat conf/secrets.worker.yaml | grep address | head -n 1 | awk -F ': ' '{print $2}')
cecho "Node has been repaired." "green"
#Current node public key constant
PUBKEY="$(get_publickey)"

#Getting the node score on the leadboard
current_score="$(get_points "$PUBKEY" )"
echo -n "Your node name is "
cecho "${node_name}." "green"
echo -n "Your address is "
cecho "${unchained_address}." "green"
if [ "$current_score" == "null" ] || [[ $(($current_score)) < 100 ]]
then
    cecho "WARNING: Your node is possibly using a newly generated secret key" "yellow"
    cecho "Please, make sure to put your old secret key in secrets.worker.yaml file."
    echo -n "Your current secret key is "
    cecho "$(show_secretkey)" "green"
else
    echo -n "Your current score on the leadboard is "
    cecho "${current_score}." "green"
    if [[ "$current_score" -lt 10000 ]]
    then
        cecho "LOW SCORE DETECTED" "yellow"
        echo "If your score should be higher then this."
        echo "Make sure you're using the right secret key in your secrets.worker.yaml file"
        echo "which resides in conf folder."
        echo -n "Your current secret key is "
        cecho "$(show_secretkey)" "green"
    fi
fi

cecho "Let's make sure your node is gaining points. Please wait..." "yellow"

if is_gaining_points 
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