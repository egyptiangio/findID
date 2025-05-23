#!/bin/bash
# findID.sh v1.1

#####################
# Configuration
#####################

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scriptName="$(basename "${BASH_SOURCE[0]}" .sh)"
CONFIG_FILE="$scriptDir/${scriptName}.conf"

# Dependencies check
for dep in jq curl; do
  if ! command -v "$dep" &> /dev/null; then
    echo "Error: '$dep' is not installed."
    exit 1
  fi
done

# Check for viu separately, allow fallback
if ! command -v viu &> /dev/null; then
  echo "Notice: 'viu' is not installed. Channel logos will not be shown."
  echo "To enable logo previews, install 'viu': https://github.com/atanunq/viu"
  wantImages=false
fi

# Load or create config
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
else
  echo "No config file found. Let's set up your Channels DVR connection."

  read -p "Enter Channels DVR IP address (default 192.168.0.10): " CHANNELS_DVR_IP
  CHANNELS_DVR_IP=${CHANNELS_DVR_IP:-192.168.0.10}

  read -p "Enter Channels DVR port (default 8089): " CHANNELS_DVR_PORT
  CHANNELS_DVR_PORT=${CHANNELS_DVR_PORT:-8089}

  echo "CHANNELS_DVR_IP=\"$CHANNELS_DVR_IP\"" > "$CONFIG_FILE"
  echo "CHANNELS_DVR_PORT=\"$CHANNELS_DVR_PORT\"" >> "$CONFIG_FILE"
  echo "wantImages=true" >> "$CONFIG_FILE"

  echo "Configuration saved to $CONFIG_FILE"
  source "$CONFIG_FILE"
fi

# Load or initialize image setting (redundant fallback)
if [[ -z "$wantImages" ]]; then
  wantImages=true
fi

tmpDir=$(mktemp -d)
trap 'rm -rf "$tmpDir"' EXIT

#####################
# Main Loop
#####################

while true; do
  echo
  echo "Enter station name or call sign to search."
  echo "Type 'imagesOn' or 'imagesOff' to toggle image display in search results."
  echo "Type 'exit' to quit."
  read -p "> " userInput

  case "$userInput" in
    exit)
      echo "Goodbye!"
      break
      ;;
    imagesOn)
      if ! command -v viu &> /dev/null; then
        echo "Error: 'viu' is not installed."
        wantImages=false
      else
        wantImages=true
        echo "Image display ENABLED."
        sed -i "" -e "/^wantImages=/d" "$CONFIG_FILE"
        echo "wantImages=true" >> "$CONFIG_FILE"
      fi
      continue
      ;;
    imagesOff)
      wantImages=false
      echo "Image display DISABLED."
      sed -i "" -e "/^wantImages=/d" "$CONFIG_FILE"
      echo "wantImages=false" >> "$CONFIG_FILE"
      continue
      ;;
    "") continue ;;
    *) stationQuery="$userInput" ;;
  esac

  encodedStationName="%22${stationQuery// /%20}%22"
  responseName=$(curl -s "http://${CHANNELS_DVR_IP}:${CHANNELS_DVR_PORT}/tms/stations/${encodedStationName}")
  responseCallSign=$(curl -s "http://${CHANNELS_DVR_IP}:${CHANNELS_DVR_PORT}/tms/stations/%22${stationQuery^^}%22")

  response=$(echo "$responseName" "$responseCallSign" | jq -s 'add | unique_by(.stationId)' 2>/dev/null)
  if [[ -z "$response" ]]; then
    echo "Error: Malformed JSON response. Check DVR connectivity."
    continue
  fi

  count=$(echo "$response" | jq length)
  if [[ "$count" -eq 0 ]]; then
    echo "No stations found matching '$stationQuery'."
    continue
  fi

  echo
  echo -e "\033[1;32mFound $count station(s).\033[0m"

  mapfile -t matches < <(echo "$response" | jq -c '.[]')
  total=${#matches[@]}
  index=0

  while [[ $index -lt $total ]]; do
    echo -e "\033[1;33m"
    printf "%-40s %-12s %-10s %-15s\n" \
      "NAME" "CALLSIGN" "VIDEO" "AFFILIATE"
    printf "%s\n" "-------------------------------------------------------------------------------------------"
    echo -e "\033[0m"

    for ((i = 0; i < 5 && index < total; i++)); do
      obj="${matches[$index]}"

      name=$(echo "$obj" | jq -r '.name // "N/A"')
      callSign=$(echo "$obj" | jq -r '.callSign // "N/A"')
      videoType=$(echo "$obj" | jq -r '.videoQuality.videoType // "N/A"')
      affiliate=$(echo "$obj" | jq -r '.affiliateCallSign // "N/A"')
      stationId=$(echo "$obj" | jq -r '.stationId // "N/A"')

      printf "%-40s %-12s %-10s %-15s\n" \
        "$name" "$callSign" "$videoType" "$affiliate"

      if $wantImages; then
        logoUrl=$(echo "$obj" | jq -r '.preferredImage.uri // ""')
        if [[ -n "$logoUrl" && "$logoUrl" != "" && "$logoUrl" != "null" ]]; then
          cleanUrl=$(echo "$logoUrl" | cut -d'?' -f1)
          fileName="$tmpDir/logo_${stationId}.png"
          curl -s -o "$fileName" "$cleanUrl"
          if [[ -s "$fileName" ]]; then
            viu -h 5 "$fileName"
          else
            echo "[No Logo Available]"
          fi
        else
          echo "[No Logo Available]"
        fi
      fi

      echo
      ((index++))
    done

    if [[ $index -lt $total ]]; then
      read -p "Show more results? (y/n): " choice
      [[ "$choice" != [Yy]* ]] && break
    fi
  done
done
