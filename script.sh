#!/usr/bin/env bash
function show_error() {
  message="$1"
  printf "$message. Exiting..."
  exit 1
}
function check_status() {
  if [ $? -ne 0 ]; then
    show_error "Error occurred"
  fi
}
function manage_existing_file_to_resign() {
  echo "Checking $ORIGINAL_FILE..."
  if [ "${ORIGINAL_FILE##*.}" = "ipa" ]; then
    # Unzip the old ipa quietly
    unzip -q "$ORIGINAL_FILE" -d temp
    check_status
    echo "unzipped ipa $ORIGINAL_FILE"
  elif [ "${ORIGINAL_FILE##*.}" = "app" ]; then
    # Copy the app file into an ipa-like structure
    mkdir -p "temp/Payload"
    cp -Rf "${ORIGINAL_FILE}" "temp/Payload/${ORIGINAL_FILE}"
    check_status
    echo "unzipped app $ORIGINAL_FILE"
  else
    show_error "Error: Resign just ipa or app files"
  fi
}
function set_target_app() {
  # Set the app name
  # The app name is the only file within the Payload directory
  TARGET_APP=$(ls temp/Payload/)
  echo "TARGET_APP=$TARGET_APP"
}
function set_display_name() {
  if [ ! -z "$DISPLAY_NAME" ]; then
    PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "temp/Payload/$TARGET_APP/Info.plist"
    echo "New Display Name: $DISPLAY_NAME"
  fi
}
function set_app_id_prefix() {
  OLD_APP_ID_PREFIX=$(grep '<key>application-identifier</key>' "temp/Payload/$TARGET_APP/embedded.mobileprovision" -A 1 --binary-files=text | sed -E -e '/<key>/ d' -e 's/(^.*<string>)//' -e 's/([A-Z0-9]*)(.*)/\1/')
  check_status
  echo "OLD_APP_ID_PREFIX=$OLD_APP_ID_PREFIX"
  NEW_APP_ID_PREFIX=$(grep '<key>application-identifier</key>' "$PROVISION_FILE" -A 1 --binary-files=text | sed -E -e '/<key>/ d' -e 's/(^.*<string>)//' -e 's/([A-Z0-9]*)(.*)/\1/')
  check_status
  echo "NEW_APP_ID_PREFIX=$NEW_APP_ID_PREFIX"
}
function set_bundle_id() {
  OLD_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "temp/Payload/$TARGET_APP/Info.plist")
  check_status
  echo "OLD_BUNDLE_ID=$OLD_BUNDLE_ID"
  NEW_BUNDLE_ID=$(egrep -a -A 2 application-identifier "${PROVISION_FILE}" | grep string | sed -e 's/<string>//' -e 's/<\/string>//' -e 's/ //' | awk '{split($0,a,"."); i = length(a); for(ix=2; ix <= i;ix++){ s=s a[ix]; if(i!=ix){s=s "."};} print s;}')
  if [[ "${NEW_BUNDLE_ID}" == *\** ]]; then
    show_error "Bundle Identifier contains a *"
  fi
  check_status
  echo "NEW_BUNDLE_ID=$NEW_BUNDLE_ID"
  ### Replace bundle identifier and BundleURLSchema contained inside Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_BUNDLE_ID" "temp/Payload/$TARGET_APP/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:1:CFBundleURLSchemes:0 $NEW_BUNDLE_ID" "temp/Payload/$TARGET_APP/Info.plist"
  #plutil -insert CFBundleDocumentTypes.0.CFBundleTypeExtensions.1 -string "*" temp/Payload/$TARGET_APP/Info.plist
  ## Update GoogleSignin URL schema
  NEW_CLIENT_ID=$(/usr/libexec/PlistBuddy -c "Print :REVERSED_CLIENT_ID" "./GoogleService-Info.plist")
  /usr/libexec/PlistBuddy -c "set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $NEW_CLIENT_ID" "temp/Payload/$TARGET_APP/Info.plist"
  ## End of update GoogleSignin URL schema
  # Uncomment to convert Info.plist to binary format
  # plutil -convert binary1 "temp/Payload/$TARGET_APP/Info.plist"
}
function set_new_app_identitifier() {
  set_app_id_prefix
  set_bundle_id
  echo "New App Identifier: ${NEW_APP_ID_PREFIX}.${NEW_BUNDLE_ID}"
}
function replace_provisioning_profile() {
  ENTITLEMENTS_TEMP=$(/usr/bin/codesign -d --entitlements - "temp/Payload/$TARGET_APP" | sed -E -e '1d' -e s/$OLD_BUNDLE_ID/$NEW_BUNDLE_ID/ -e s/$OLD_APP_ID_PREFIX/$NEW_APP_ID_PREFIX/)
  echo "ENTITLEMENTS_TEMP=$ENTITLEMENTS_TEMP"
	if [ -n "$ENTITLEMENTS_TEMP" ]; then
		echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>$ENTITLEMENTS_TEMP" >temp/newEntitlements.xml
	fi
	cp "$PROVISION_FILE" "temp/Payload/$TARGET_APP/embedded.mobileprovision"
	check_status
}
function resign_app() {
  # /usr/bin/codesign -f -s "$CERTIFICATE" --entitlements="$ENTITLEMENTS" --resource-rules="temp/Payload/$TARGET_APP/ResourceRules.plist" "temp/Payload/$TARGET_APP"
  # check_status
  /usr/libexec/PlistBuddy -c "Set :application-identifier ${NEW_APP_ID_PREFIX}.${NEW_BUNDLE_ID}" temp/newEntitlements.xml
  check_status
  /usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" temp/newEntitlements.xml
  # /usr/libexec/PlistBuddy -c "Delete :aps-environment" temp/newEntitlements.xml
  /usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string ${NEW_APP_ID_PREFIX}.\*" temp/newEntitlements.xml
  check_status
  plutil -lint temp/newEntitlements.xml
  check_status
  /usr/bin/codesign -f -s "$CERTIFICATE" --entitlements="temp/newEntitlements.xml" "temp/Payload/$TARGET_APP"
  check_status
  rm temp/newEntitlements.xml
}
function finalize() {
  echo "Creating ipa..."
  cd temp/
  zip -qr ../app-resigned.ipa Payload/ BCSymbolMaps/ SwiftSupport/
  cd ..
  echo "Create app-resigned.ipa"
  rm -rf "temp"
}
if [[ ${#3} -eq 0 ]]; then
  show_error "\nHow to use: \n  $ ${0##*/}   path/to/ipa_or_app_to_sign   path/to/profile   Certificate(='iPhone Distribution: Name') \n\nTry again"
fi
ORIGINAL_FILE="$1"
PROVISION_FILE="$2"
CERTIFICATE="$3"
DISPLAY_NAME="$4"
manage_existing_file_to_resign
set_target_app
set_display_name
set_new_app_identitifier
replace_provisioning_profile
resign_app
finalize