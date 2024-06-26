#!/bin/bash
#: Date: 4/27/2024
#: Author: Ammar Salmi
#: Version: 1.3.5
#: Description: Tool to fix, update, and reinstall unchained node run on docker in linux systems


## Constants
## the docker image name for unchained worker
CONTAINER_NAME="unchained_worker"

## File paths
CONF_FILE_PATH="conf/conf.worker.yaml"
SECRETS_FILE_PATH="conf/secrets.worker.yaml"
## Default value for timeout when monitoring points increase on leadboard
POINTS_TIMEOUT=39
## A variable so latest stable  release is only fetched once from the internet
LATEST_RELEASE=""
## Welcome message and explanation
echo "#################################################################################"
echo "# Unchained Ironsmith                                                           #"
echo "# A community-made tool to help diagnose and fix unchained node problem.        #"
echo "# v1.3.5 Supports only docker nodes. Tested only on ubuntu, debian, and centos  #"
echo "#################################################################################"

## Declaring functions here
## Colored output function
cecho() {
    case $2  in
    'green')
        tput setaf 10; echo "$1" && tput sgr0
        #echo -e "\e[32m$1\e[0m"
        ;;
    'yellow')
        tput setaf 11; echo "$1" && tput sgr0
        #echo -e "\e[33m$1\e[0m"
        ;;
    'red')
        tput setaf 9; echo "$1" && tput sgr0
        #echo -e "\e[31m$1\e[0m"
        ;;
    *)
        echo "$1"
        ;;
    esac
}

## Importing key from the backed up file
import_original_key() {
    ## Importing og secret key
    cecho "importing original secret key" "green"
    if [ -f $backup_file_name ] 
    then
        if [[ -z $chosen_key ]]; then
            original_key=$(sudo awk -F': ' ' /secret/ {print $2}' $backup_file_name) 
        else 
            original_key=$chosen_key
        fi
        current_key=$(sudo awk -F': ' ' /secret/ {print $2}' $SECRETS_FILE_PATH) 
        if [[ $current_key == $original_key ]]; then
            cecho "Your node is already using the original key" "green"
            return 0
        else 

        sudo sed -i "s/$current_key/$original_key/" $SECRETS_FILE_PATH
        sudo sed -i "/address\|public/d" $SECRETS_FILE_PATH
        PUBKEY=$(get_publickey)
        ## updating current key
        current_key=$(sudo awk -F': ' ' /secret/ {print $2}' $SECRETS_FILE_PATH) 
        if [[ $current_key == $original_key ]]; then
            cecho "Original key imported and node restarted successfully" "green"
        else
            cecho "Couldn't import orginal key. Please do it manually. It's stored in file $backup_file_name." "yellow"
        fi
        fi
    else
        cecho "Can't find the backup file for your secret key" "yellow"
    fi
}
 
## Goodbye message
goodbye() {
    local result=$1
    case "$result" in

    success)
        cecho "You're node is now repaired. Thank you for using IronSmith." "green"
        ;;

    failure)
        cecho "The node is still broken. Sorry we coudn't help" "red"
        ;;
    
    *)
        echo "Goodbye"
        ;;
    
    esac

    echo "For further help, please visit us at https://t.me/KenshiTech. Find us in Unchained channel."
    exit 0
}
## Using inspect to check docker container various states
function check_container_state()
{
    ## Lowercase the argument
    state_label=${1,,}
    case $state_label in
        run|running)
            container_state=$(sudo docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME") &> /dev/null && \
            [ "$container_state" == "true" ] || \
            false
            ;;
        rest|restarting)
            ## Docker often needs time to set .Restarting to true when node is restarting
            container_state=$(sudo docker inspect --format='{{.State.Restarting}}' "$CONTAINER_NAME") &> /dev/null && \
            [ "$container_state" == "true" ] || \
            false
            ;;
        *)
            echo "check_container_state function doesn't recognize the queried lable"
            return 1
            ;;
    esac
}
## Recover secretkey from file using simple awk parsing command
get_secret_key() {
    local path=${1:-$SECRETS_FILE_PATH}
    [[ -f $path ]] && sudo awk -F': ' ' /secret/ {print $2}' $path
}
## Grab secret key from secrets file and obscure most of it
show_secretkey() {
    local secretkey=$(get_secret_key) || echo "Can't find secrets.worker.yaml"
    local first4chars=${secretkey: 0:4}
    local last4chars=${secretkey: -4}
    echo "$first4chars**********$last4chars"
}

## A function to check if container is running
is_running() {
    check_container_state "running"
}

## A function to check if container is restarting
is_restarting() {
    check_container_state "restarting"
}

get_logs_path() {
    container_logs=$(sudo docker inspect --format='{{.LogPath}}' "$CONTAINER_NAME")
    echo "$container_logs"
}

count_lines() {
    sudo cat "$(get_logs_path)" | wc -l
}

is_healthy() {
    printf "Checcking node health. Please wait...\n"
    SLEEP_TIME=3
    total_sleep=0
    num_lines=$(count_lines)
    num_new_lines=0
    while (( num_new_lines < 11 )) && (( total_sleep < 180 ))
    do
        sleep $SLEEP_TIME
        (( total_sleep+=$SLEEP_TIME ))
        new_count=$(count_lines)
        num_new_lines=$(( num_new_lines + new_count - num_lines ))
        num_lines=$new_count
    done
    (( total_sleep >= 180 )) && cecho "health checking timed out!" "yellow"
    container_logs=$(sudo tail -n 11 "$(get_logs_path)")
    [[ $(grep -cvE "INF|ERR" <<< "$container_logs") == 0 ]] && (( total_sleep < 179 ))
}

## TO-DO this function needs to be able to check WSS protocol 
check_rpc() {

## JSON-RPC request data
REQUEST='{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

## Send the JSON-RPC request using curl
response=$(curl -s -X POST -H "Content-Type: application/json" --data "$REQUEST" "$1")

[[ "$response" =~ "result" ]]
}
## get the rpcs position in conf file
get_RPCs_line_num() {
    line_num=0
    while IFS= read line 
    do
    ((line_num++))
    case ${line,,} in
        rpc:*) break ;;
    esac
    done < $CONF_FILE_PATH
    echo $((line_num + 2))
}

## If we add a working rpc but some of them are not responding, the node will still give rpc error
## This function was created to remove bad rpcs
remove_bad_rpcs() {
    ## Parsing the conf file to get all links except for broker
    rpcs_links=$(sudo awk -F '- ' ' /:\/\// && !/broker/ && !/sepolia/ {print $2}' $CONF_FILE_PATH)

    ## Loop through the list parsed from conf.worker.yaml
    num_links_left=0
    while IFS= read -r link; do
        ((num_links_left++))
        if ! check_rpc "$link"; then
            # Remove the line containing the link from conf.yaml
            short_link=${link#*//}
            short_link=${short_link%%/*}
            sudo sed -i "/${short_link}/d" $CONF_FILE_PATH
            echo "Removing bad rpc: $link"
            ((num_links_left--))
        else
            echo "$link seems good"
        fi
    done <<< $rpcs_links
    ! (( num_links_left ))
}

## Check the node logs for the currently used unchained version
get_current_version()  {
    ## Check current version
    version=$(sudo grep Version "$(get_logs_path)" | tail -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 )
    echo "$version"
}

## Get the latest stable release from release page on github
## TO-DO It's hard-coded and might need more finess to able to adapt in possible pages in the web page
## TO-DO check internet connectivity function is needed
get_latest_version() {
    if [ -z "$LATEST_RELEASE" ]
    then
        local latest_version=$(curl -s "https://github.com/TimeleapLabs/unchained/releases" | grep 'releases/tag/v' | grep -iEv 'alpha|beta|rc'| head -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        LATEST_RELEASE="$latest_version"
        echo "$latest_version"
    else
        echo "$LATEST_RELEASE"
    fi
}

## Compare the current version of the node to the latest stable release
is_uptodate() {
current_version="$(get_current_version)"
latest_version="$(get_latest_version)"
[[ "$latest_version" == "$current_version" ]]
}

## Check the release page if the most recent push is stable or alpha, beta, rc
is_latest_stable() {
    releases_url="https://github.com/TimeleapLabs/unchained/releases"
    release=$(curl -s $releases_url | grep 'releases/tag/v' | head -n 1 | grep -iE 'alpha|beta|rc')
    [ -z "$release" ]
}

## Simple pull and "up -d" sequence
pull_and_recreate() {
    cecho "Pulling latest image..." "yellow"
    update_response=$({ sudo ./unchained.sh worker pull; } 2>&1)
    cecho "Removing container..." "yellow"
    sudo docker ps | grep -q $CONTAINER_NAME  && remove_container_response=$({ sudo docker rm --force $CONTAINER_NAME;} 2>&1)
    cecho "Starting up the node..." "yellow"
    starting_response=$({ sudo ./unchained.sh worker up -d --force-recreate; } 2>&1)
    echo "update response: $update_response || remove container response:$remove_container_response || recreate response: $starting_response" 
}

## Trying to update the node without catching an alph/beta/rc release by mistake
safe_update() {
    if is_latest_stable
    then
        ## Updating the node with regular "pull" and "up -d"
        cecho "Attempting to update with regular pull since latest image is a stable release" "yellow"
        response=$(pull_and_recreate)
        sleep 2
        if is_uptodate 
        then
            cecho "Node was updated successfully with a regular pull" "green"
            return 0
        else
            cecho "Node update failed" "red"
            cecho "responses from update attempt:" "yellow"
            echo -e "$response"
            return 1
        fi
    else
        ## Dodging alpha release
        cecho "Latest image is not stable. Attempting to circumvent unstable release..." "yellow"
        ## removing the image tagged as latest since it's not the latest stable release
        cecho "Removing latest image from your machine..." "yellow"
        sudo docker rmi --force ghcr.io/timeleaplabs/unchained:latest 1> /dev/null
        cecho "Pulling latest stable image..." "yellow"
        latest_stable=$(get_latest_version)
        sudo docker pull ghcr.io/timeleaplabs/unchained:v"$latest_stable" >/dev/null
        cecho "Tagging image as latest..." "yellow"
        sudo docker tag ghcr.io/timeleaplabs/unchained:v"$latest_stable" ghcr.io/timeleaplabs/unchained:latest >/dev/null
        cecho "Removing container..." "yellow"
        sudo docker rm --force $CONTAINER_NAME >/dev/null
        cecho "Starting up a node with stable release image..." "yellow"
        sudo ./unchained.sh worker up -d > /dev/null 1>&2
        sleep 2
        if  is_uptodate  
            then
            cecho "Node was updated successfully to latest stable release" "green"
            return 0
        else
            echo "Node update failed"
            return 1
        fi
    fi

}

## Get the current node public key
get_publickey() {
    attempts=0
    while ! grep -q public $SECRETS_FILE_PATH && (( attempts < 4))
    do
        cecho "Public key wasn't generated. Restarting the node to create it" "yellow"
        sudo sudo docker stop $CONTAINER_NAME &> /dev/null
        sudo sudo docker start $CONTAINER_NAME &> /dev/null
        ((attempts++))
    done
    pubk=$(sudo awk -F ': ' ' /public/ {print $2}' $SECRETS_FILE_PATH)
    echo $pubk
}

## Get the current node unchained address
get_address() {
    secrets_file=${1:-$SECRETS_FILE_PATH}
    address=$( sudo awk -F': ' ' /address/ {print $2}' "$secrets_file" )
    echo "$address"
}

## Use API to fetch the node points on the scoreboard
get_points() {
    hex_key=${1:-$PUBKEY}
    
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
    echo $points
}


## Monitor node for score increase
is_gaining_points()  {
    ## First argument is a public key or defaulting to the current node key
    local publicKey="${1:-$PUBKEY}"
    ## Modifing the output string to fit whether we're checking the current node or top nodes
    [[ $publicKey == $PUBKEY ]] && \
    cecho "Checking if your node is gaining points. Please be patient. This could take a while..." "yellow"
    
    ## How long it should wait to come to a conclusion about gaining point
    local timeout=${2:-$POINTS_TIMEOUT}
    
    ## Getting the score every 3 seconds till timemout is reached or score increase detected    
    current_score=$(get_points $publicKey);
    points_0=$((current_score));
    updated_points="$current_score";
    points_1=$((updated_points));
    waiting_time=0;
    TIME_INCREMENT=3;
    while (( points_1 == points_0 )) && (( waiting_time < timeout ));
    do
        sleep "$TIME_INCREMENT";
        updated_points=$(get_points $publicKey);
        points_1=$((updated_points));
        ((waiting_time += $((TIME_INCREMENT)) ));
    done
    gained_points=$((points_1 - points_0));
    [[ $(($gained_points)) > 0 ]]
    }

## Checking if all nodes are not getting points for some global error
is_broker_down() {
    public_keys=(
    ## ammarubuntu node
    "8cafe3f3630e8a49bfc6fae1a3d4bd5db38458e34b781886f75cb8f25296416763a9e9feb1ef7da041238edcdbdaa63412445eb9030d2c9f58bbda0f7397a7cfeaf1fdf671de8dd7c42ca1010bf4d452d0d4889cb94439d004dd76a148d9a60f"
    ## ammardebian node
    "96279fd86b29c018126f8be1c072095cbc2fc35f3933da38ce12e21c56e2e217f4735c4bf170675c0dd10b844e1b8ff6185b932214b266d3c5a6fb6901016db1a67d34606e6da75f6008126004279637f499c27cfe2bd691b12bf16c9fe8f714"
    ## jay's node
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
## Table graphics
print_keys_table_header() {
    printf "########################################################################\n"
    printf "# N #     Secret Key     #    Score  #          Observation            #\n"
    printf "########################################################################\n"
}

print_keys_table_footer() {
    printf "########################################################################\n"
}
## Scan the machine for possible backup of private keys
fetch_secretkeys() {
    ## Finding all files containing a secretkey
    files_with_keys=$(sudo grep -lirE "secretkey: [0-9abcdef]{64}" $HOME)
    ## Declaring local variables
    local keysArray=()
    local scoresArray=()
    local triedKeys="*******"
    local pubKey=""
    local secretKey=""
    local score=0
    local key_index=0
    local max_score=0
    local max_index current_secret_key

    ## Checking all files for keys
    echo $files_with_keys
    while IFS= read filepath
    do
    ## TODO Covering the case where public key is base58 not a hex
    pubKey=$(sudo awk -F ': ' ' /public/ {print $2} ' $filepath )
    secretKey=$(get_secret_key $filepath ) 
    [[ "$folder" == "${filepath%/$SECRETS_FILE_PATH}" ]] && current_secret_key=$secretKey
    case "$triedKeys" in
        ## Checking if the public key is redundant
        *"$pubKey"*) 
            continue;
            ;;
        *)
            ## Adding the key and score to their respective tables
            [[ -z $pubKey ]] && continue
            score=$(get_points $pubKey);
            [[ $score -gt $max_score ]] && max_index=$key_index && max_score=$score
            triedKeys=${pubKey}${triedKeys}
            keysArray[$key_index]=$secretKey && scoresArray[$key_index]=$score && ((key_index++))
            ;;
    esac
    done <<< $files_with_keys
    local num_of_keys=${#keysArray[@]}
    echo "We found $num_of_keys keys"
    [[ $num_of_keys < 2 ]] && cecho "Only one key was found on your machine" "yellow" && return 1
    cecho "Multiple keys detected on your machine..."
    print_keys_table_header
    for ((i=0; i < $num_of_keys; i++))
    do
        local obs=""
        [[ $max_index == $i ]] && obs=${obs:+$obs" and"}" Max points" 
        [[ $current_secret_key == ${keysArray[$i]} ]] && obs=${obs:+$obs" and"}" Current key" 
        printf "#%2d # %s******** # %9d # %-31s #\n" "$((i+1))" "${keysArray[$i]:0:10}" "${scoresArray[$i]}" "$obs"
    done
    print_keys_table_footer
    ## Respecting grammar :D
    (( num_of_keys > 1 )) && str1="s" && str2="were"
    printf "%d key%s %s found on your machine.\n" "$num_of_keys" "${str1-""}" "${str2-"was"}"  
    printf "Which key do you want to import? (1-%d) or just ENTER to keep the current key : " "$num_of_keys"    
    while :
    do
        read -r key_choice 
        ## Make sure chosen number is within range
        (( key_choice > num_of_keys )) && key_choice=0
        case $key_choice in
            [1-9][0-9]|[1-9]|"")
                if [[ -z $key_choice ]]; then
                    chosen_key=$current_secret_key
                else
                    index=$(($key_choice - 1))
                    chosen_key=${keysArray[$index]}
                fi
                printf "Importing key: %s*********\n" "${chosen_key:0:10}"
                break
                ;;
            *) 
                printf "Invalid input. Please choose a number between 1 and %d or just press ENTER to keep the current key: " "$num_of_keys" 
                ;;
        esac
    done
}
######################################
## THE END OF FUNCTION DECLARATIONS ##
######################################

## Detect linux dist and set the appropriate package manager
## Some commands like wget, jq may not be installed by default on some machines
## They are needed for this script to run properly

INSTALL_COMMAND="install"
if command -v apt &>/dev/null; then
    PKG_MNGR="apt"
elif command -v yum &>/dev/null; then
    PKG_MNGR="apt"
elif command -v dnf &>/dev/null; then
    PKG_MNGR="apt"
elif command -v pacman &>/dev/null; then
    PKG_MNGR="apt"
    INSTALL_COMMAND="-S"
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

## Installing necessary tools
cecho "Installing necessary commands for the script: wget, curl, jq " "yellow"
command -v jq &>/dev/null || { sudo "$PKG_MNGR" "$INSTALL_COMMAND" jq -y &>/dev/null; }
command -v curl &>/dev/null || { sudo "$PKG_MNGR" "$INSTALL_COMMAND" curl -y &>/dev/null; }
command -v wget &>/dev/null || { sudo "$PKG_MNGR" "$INSTALL_COMMAND" wget -y &>/dev/null; }

## Checking if docker version 2 is installed
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


## Detecting the working directory of unchained node
cecho "Attempting to auto-detect working directory of your node..." "yellow"
folder=""
if ! sudo docker inspect "$CONTAINER_NAME" &> /dev/null
then
    cecho "Error: $CONTAINER_NAME container doesn't exist" "red"
    cecho "Attempting to locate unchained folder" "yellow"
    
    ## navigating to home directory
    cd ~ || { echo "Error: Failed to change directory to the home directory."; exit 1; }
    
    # Store search results in an array
    mapfile -t files < <(sudo find $HOME -maxdepth 5 -type d -name "*unchained*" -exec sudo find {} -type f -name "unchained.sh" -printf "%h\n" \;)

    # Check if any files were found
    if [ ${#files[@]} -eq 0 ]; then
        cecho "Error: No unchained directory was found on home directory" "red"
        exit 1
    fi

    # Display options to the user
    echo "Which is your working directory of unchained node:"
    select option in "${files[@]}"; do
        if [ -n "$option" ]; then
            folder="${option}"
            break
        else
            echo "Invalid option. Please try again."
        fi
    done
else
    # Inspecting unchained container to grab the working directory
    # Get the Docker inspect output
    folder=$( sudo docker inspect --format='{{json .Config.Labels}}' "$CONTAINER_NAME" | jq -r '.["com.docker.compose.project.working_dir"]' )
fi

## Change directory to the folder where the Docker container was created
if [ ! -z "$folder" ]
then
    cecho "Working directory detected: $folder" "green"
    cecho "Navigating to directory: $folder" "yellow"
    cd "$folder" ||  { echo "Error: Failed to change directory to $folder."; exit 1; }
    cecho "Starting the node from $(pwd)" "yellow"
else
    cecho "Unable to detect working directory of unchained node" "red"
    exit 1
fi

## Facilitating keys recovery
fetch_secretkeys

cecho "Making sure the compose file is not using old image links (kenshitech)..." "yellow"
sudo sed -i.bak 's/kenshitech/timeleaplabs/g' compose.yaml 

## Backing up secret key
cecho "Backing up secret key" "yellow"
if [[ -f "$SECRETS_FILE_PATH" ]] 
then
    ## Make sure not have redundant backups
    key=$(get_secret_key)
    backup_file_name=secrets.bak.${key:0:3}${key: -3}
    [[ -f $backup_file_name ]] || sudo cp $SECRETS_FILE_PATH  $backup_file_name
    if [[ -f "$backup_file_name" ]] &&  grep -q secret $backup_file_name ; then
        address=$(get_address $backup_file_name)
        
        ## Puttin the apropriate labels in secrets to avoid creating new key pair
        sudo sed -i 's/k/K/g' $SECRETS_FILE_PATH

        cecho "Secret key backed up successfully in $backup_file_name for the address: $address." "green"
    else
        cecho "Secret key couldn't be backed up. Please do it manually before updating or using this script again."
        exit 1
    fi
else
    cecho "Can't back up secret key. Back it up manually first." "red";
    while :
    do
        read -p "Do you want to continue anyway?(y/n)" cont_answer
        case $cont_answer in
            y|Y) break ;;
            n|N) exit 1 ;;
            *) echo "Invalid answer"
        esac
    done
fi

## Importing the chosen key into the secrets file


cecho "Checking if the node is running..." "yellow"
start_node_escalation=1
response=""
while ! is_running
do
    cecho "The node is not running" "red"
    case $start_node_escalation in
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

## Check restarting status to determin if there is a problem with the node

## Getting node name
node_name=$(sudo awk -F ': ' ' /name/ && !found {print $2; found=1}' $CONF_FILE_PATH)
fix_node_escalation=1
response=""
while ! is_healthy 
do
    case $fix_node_escalation in
        1)
            cecho "Fixing the error attempt $fix_node_escalation: updating conf file." "yellow"
            ## DONE: detecting generic node names with regex
            if [ -z "$node_name" ] || [ "$node_name" == '<name>' ] || [[ "$node_name" =~ [a-zA-Z]+-[a-zA-Z]+-[a-zA-Z]+ ]]
            then
                    echo "Generic or null name detected: $node_name."
                    read -r -p "Please, enter your perfered node name or press ENTER to keep the same name: " answer
            fi
            ## Increasing timeout if name changed since detecting points take longer if name is changed
            [ -z "$answer" ] && new_node_name="$node_name" || { new_node_name="$answer"; POINTS_TIMEOUT=60; }
            echo "Setting your node name to $new_node_name"
            node_name=$new_node_name
            ## Make sure wget is on the system
            sudo wget -q https://raw.githubusercontent.com/TimeleapLabs/unchained/master/conf.worker.yaml.template -O conf.yaml 
            sudo sed -i "s/<name>/$new_node_name/g" conf.yaml
            sudo mv conf.yaml $CONF_FILE_PATH
            sudo ./unchained.sh worker restart 2>/dev/null
            ((fix_node_escalation++))
            ;;
        2)
            cecho "Fixing the error attempt $fix_node_escalation: updating the node." "yellow"
            safe_update
            ((fix_node_escalation++))
            ;;
        3)
            cecho "Fixing the error attempt $fix_node_escalation: LAST ATTEMPT: reinstall." "yellow"
            while :
            do
                read -r -p "Would you like to reinstall the node from scratch?(y/n)" choice
                choice=${choice,,}
                case $choice in
                    y|yes)
                        break
                        ;;
                    n|no)
                        goodbye "failure"
                        break
                        ;;
                    *)
                        echo "Please type y for yes or n for no."
                        ;;
                esac
            done
            ## Reinstalling from scratch as last resort to fix node
            cecho "Reinstalling your node..." "yellow"

            cecho "Navigating to your home directory..." "yellow"
            cd ~ || { echo "Couldn't get to home directory"; exit 1; }

            ## Making sure unzip is installed
            command -v unzip &>/dev/null || { sudo "$PKG_MNGR" "$INSTALL_COMMAND" unzip -y &>/dev/null; }

            ## Parsing latest release version number from releases page on github
            latest=$(get_latest_version)

            cecho "Downloading docker zip file..." "yellow"
            sudo wget -q https://github.com/TimeleapLabs/unchained/releases/download/v"$latest"/unchained-v"$latest"-docker.zip -O unchained-v"$latest"-docker.zip

            cecho "Unziping downloaded file..." "yellow"
            sudo unzip unchained-v"$latest"-docker.zip 1> /dev/null || { echo "Couldn't unzip file"; exit 1; }

            cecho "Navigating to decompressed folder..." "yellow"
            cd unchained-v"$latest"-docker

            cecho "Removing old unchained container..." "yellow"
            sudo docker rm --force $CONTAINER_NAME 1> /dev/null
            
            ## Importing old keys
            if [[ ! -z $folder ]] && [[ -d $folder/conf ]]; then
                old_directory=$folder
                cecho "Importing old conf and secrets files and starting the node..." "yellow"
                sudo cp -r "$old_directory"/conf .

                ## Double check the conf file is fixed
                sudo wget -q https://raw.githubusercontent.com/TimeleapLabs/unchained/master/conf.worker.yaml.template -O $CONF_FILE_PATH
                
                ## Importing old name
                node_name=$( sudo awk -F ': ' ' /name/ && !found { print $2; found=1 }' "$old_directory"/$CONF_FILE_PATH )
                sudo sed -i "s/<name>/$node_name/g" $CONF_FILE_PATH
            fi
            ## Starting the node
            cecho "Starting the node from ${PWD}..."
            sudo sed -iBACKUP 's/kenshitech/timeleaplabs/g' compose.yaml
            sudo ./unchained.sh worker up -d --force-recreate &> /dev/null
            ((fix_node_escalation++))
            ;;
        4)
            if remove_bad_rpcs; then  
            cecho "Possible bad rpc in conf. Adding merkle..." "yellow"
            RPCs_line=$(get_RPCs_line_num)
            sudo head -n $RPCs_line $CONF_FILE_PATH > temp.yaml  
            echo "    - https://eth.merkle.io" >> temp.yaml 
            sudo tail -n +"$((RPCs_line + 1))" $CONF_FILE_PATH >> temp.yaml 
            sudo mv temp.yaml $CONF_FILE_PATH
            sudo ./unchained.sh worker restart &> /dev/null
            sleep 3
            fi
            ((fix_node_escalation++))
            ;;
        *)
            cecho "All possible fixes have been tried." "red"
            break
            ;;
    esac
done

## Current node public key constant
PUBKEY=$(get_publickey)
fix_node_escalation=0
response=""
while ! is_gaining_points 
do
    case $fix_node_escalation in
        0)
            cecho "Your node is not gaining points." "red"
            cecho "Restarting the node..." "yellow"
            sudo docker restart $CONTAINER_NAME &> /dev/null
            ;;
        1)
            cecho "Checking rpc problem." "yellow"
            if sudo tail -n 10 "$(get_logs_path)" | grep ERR | grep -qi rpc 
            then
                ## TO-DO the line number of rpcs is still hardcoded
                if remove_bad_rpcs; then  
                cecho "Possible bad rpc in conf. Adding merkle..." "yellow"
                RPCs_line=$(get_RPCs_line_num)
                sudo head -n $RPCs_line $CONF_FILE_PATH > temp.yaml  
                echo "    - https://eth.merkle.io" >> temp.yaml 
                sudo tail -n +"$((RPCs_line + 1))" $CONF_FILE_PATH >> temp.yaml 
                sudo mv temp.yaml $CONF_FILE_PATH
                sudo ./unchained.sh worker restart &> /dev/null
                sleep 3
                fi
            else
                cecho "No bad rpc error detected" "yellow"
            fi
            ((fix_node_escalation++))
            ;;
        *)
            cecho "All possible fixes have been tried." "red"
            cecho "Checking if the problem is with the brokers not with your node. This could take a while..." "yellow"
            if  is_broker_down 
            then
                cecho  "Brokers are possibly down.The problem is not on your part." "green"
                goodbye 
            else
                cecho "Other nodes are gaining points. The problem is on your part." "red"
                goodbye "failure"
            fi
            break
            ;;
    esac
done

import_original_key

## Updating public key after importing the original key
PUBKEY=$(get_publickey)

unchained_address=$(get_address)

## Getting the node score on the leadboard
current_score=$(get_points)
echo -n "Your node name is "
cecho "${node_name}." "green"

[[ ! -z $unchained_address ]] && echo -n "Your address is " && cecho "${unchained_address}." "green"
if [ "$current_score" == "null" ] || [[ $(($current_score)) < 100 ]]
then
    cecho "WARNING: Your node is possibly using a newly generated secret key" "yellow"
    cecho "Please, make sure to put your old secret key in secrets.worker.yaml file."
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

cecho "Your node is currently gaining points." "green" 
goodbye "success"
    

