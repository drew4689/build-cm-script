#!/bin/bash
# PARAMS:
# $1: Target ID (for example mb526).
# $2: "Name" of the ROM (this will be used as folder in the ROM_OUTPUT_DIRECTORY).
# PWD: This script has to be started from the "source code" folder.

BIN_DIR=${BIN_DIR:-"/home/android/"}
ROM_DATABASE_SCRIPT_DIR=${ROM_DATABASE_SCRIPT_DIR:-"${BIN_DIR}/cm-update-api/"}

DEVICE_ID=${DEVICE_ID:-"$1"}
ROM_SUBDIRECTORY=${ROM_SUBDIRECTORY:-"$2"}
LOCAL_MANIFEST=${LOCAL_MANIFEST:-"$3"}

if [[ -z "${DEVICE_ID}" ]]
then
	echo "Argument #1 (device ID) is required!"
	exit 1
fi

if [[ -z "${ROM_SUBDIRECTORY}" ]]
then
	echo "Argument #2 (ROM subdirectory) is required!"
	exit 1
fi

echo "Build-script was called for target '${DEVICE_ID}' and result directory '${ROM_SUBDIRECTORY}'."

PUBLIC_ROM_DIRECTORY=${PUBLIC_ROM_DIRECTORY:-"${BIN_DIR}/roms/${ROM_SUBDIRECTORY}"}
INCREMENTAL_UPDATES_DIRECTORY=${INCREMENTAL_UPDATES_DIRECTORY:-"${BIN_DIR}/incrementals/${ROM_SUBDIRECTORY}"}
TARGET_FILES_DIRECTORY=${TARGET_FILES_DIRECTORY:-"${BIN_DIR}/targetfiles/${ROM_SUBDIRECTORY}"}

ROM_OUTPUT_DIR="out/target/product/${DEVICE_ID}/"
TARGET_FILES_OUTPUT_DIR="${ROM_OUTPUT_DIR}/obj/PACKAGING/target_files_intermediates/"

PARALLEL_JOBS=${PARALLEL_JOBS:-1}

DELETE_ROMS_OLDER_THAN=${DELETE_ROMS_OLDER_THAN:-7}

# NOTE: -mtime only includes files older than N _full_ days - thus we subtract 1.
# See: http://unix.stackexchange.com/questions/92346/why-does-find-mtime-1-only-return-files-older-than-2-days
DELETE_ROMS_FIND_MTIME=$((${DELETE_ROMS_OLDER_THAN} - 1))

set -e
set -o xtrace
set -o pipefail

source "$(dirname $(readlink -f "${BASH_SOURCE:-$0}"))/rom-database-commands.sh"

# Building will fail of no valid locale is set.
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

# Let's make sure JAVA_HOME is in our path and found first.
if [ ! -z "${JAVA_HOME}" ]
then
	echo "Using JDK from '${JAVA_HOME}'."
	export PATH="${JAVA_HOME}/bin:${PATH}"
fi

if [ -n "${LOCAL_MANIFEST}" ]
then
	echo "Using local manifest: ${LOCAL_MANIFEST}"

	if ls .repo/local_manifests/*.xml 1> /dev/null 2>&1
	then
		rm .repo/local_manifests/*.xml
	elif [[ ! -d ".repo/local_manifests" ]]
	then
		mkdir ".repo/local_manifests"
	fi

	SOURCE_MANIFEST_FILEPATH=$(readlink -e "./.repo/manifests/${LOCAL_MANIFEST}")
	ln -s "${SOURCE_MANIFEST_FILEPATH}" .repo/local_manifests/
fi

export USE_CCACHE=${USE_CCACHE:-1}
export CCACHE_COMPRESS=${CCACHE_COMPRESS:-1}

if [[ -z "${CCACHE_DIR}" ]]
then
	export CCACHE_DIR="${BIN_DIR}/.ccache/"
fi

if [[ "${SKIP_REPO_SYNC}" == "true" ]]
then
	echo "Skipping 'repo sync'"
else
	SOURCE_TIMESTAMP=$(date +"%s")

	echo "Starting 'repo sync'..."
	time repo sync
fi

export CM_BUILDTYPE=${CM_BUILDTYPE:-NIGHTLY}

# This was required pre-cm12, but removed in cm12
if [ -s "vendor/cm/get-prebuilts" ]
then
	echo "Getting CM prebuilts..."
	time vendor/cm/get-prebuilts
fi

echo "Setting up build environment..."
. ./build/envsetup.sh

IONICE="ionice -c3"
SCHEDULING="${IONICE} schedtool -B -n19 -e"

if [[ "${SKIP_MAKE_CLEAN}" == "true" ]]
then
	echo "Skipping make clean"

	# Remove potentially stale files.
	rm -f $ROM_OUTPUT_DIR/cm-*.zip
	rm -f $ROM_OUTPUT_DIR/incremental*.zip
	rm -f $ROM_OUTPUT_DIR/md5sum
	rm -f $TARGET_FILES_OUTPUT_DIR/cm_*.zip
	rm -f $ROM_OUTPUT_DIR/system/build.prop
else
	echo "Cleaning output directory..."
	time $SCHEDULING make -j${PARALLEL_JOBS} clean
fi

# Required, because otherwise CM won't build.
set +e
set +o xtrace

echo "Configuring build..."
time breakfast "${DEVICE_ID}" || exit 1

echo "Starting build..."
time $SCHEDULING make -j${PARALLEL_JOBS} bacon || exit 1

echo "Finished build!"

set -e
set -o xtrace

TARGET_ROM_ZIP=$(readlink -f $ROM_OUTPUT_DIR/cm-*.zip)
TARGET_ROM_MD5SUM=$(readlink -f $TARGET_ROM_ZIP.md5sum)
TARGET_FILES_ZIP=$(readlink -f $TARGET_FILES_OUTPUT_DIR/cm_*target*.zip)

# Don't use absolute paths in the md5sum file.
sed -r -i "s|$(readlink -e ${ROM_OUTPUT_DIR})/?||g" $TARGET_ROM_MD5SUM

ls -la ${PUBLIC_ROM_DIRECTORY}

echo "Removing builds older than ${DELETE_ROMS_OLDER_THAN} days..."

# Remove old builds.
for FILE in $(find "${PUBLIC_ROM_DIRECTORY}" -type f -mtime +${DELETE_ROMS_FIND_MTIME} -print)
do
	echo "Removing '${FILE}'..."

	if [[ $FILE =~ \.zip$ ]]
	then
		rom_db_disable_build "${DEVICE_ID}" "${ROM_SUBDIRECTORY}" "$(basename "${FILE}")"
	fi

	rm $FILE
done

ls -la ${PUBLIC_ROM_DIRECTORY}

if rom_db_is_available
then
	MD5SUM="$(cut -d' ' -f1 "${TARGET_ROM_MD5SUM}")"
	CHANGELOG_FILE="$(readlink -e "${ROM_OUTPUT_DIR}")/all-projects-changelog.txt"
	CHANGELOG_SINCE="$(rom_db_get_source_timestamp "${DEVICE_ID}" "${ROM_SUBDIRECTORY}")"

	# Only generate the changelog if we have a "start" value.
	if [[ -n "${CHANGELOG_SINCE}" ]]
	then
		echo "Generating changelog (since ${CHANGELOG_SINCE})... "
		repo forall -p -c "git log --oneline --since "${CHANGELOG_SINCE}"" > $CHANGELOG_FILE
	else
		echo "Skipping changelog since no 'start' was found... "
		echo "(unknown)" > $CHANGELOG_FILE
	fi

	# Formatting for CMUpdater.
	sed -r -i 's|^project[ ](.*)[/]$|   \* \1|g' "${CHANGELOG_FILE}"

	rom_db_add_build \
		"${DEVICE_ID}" \
		"${ROM_SUBDIRECTORY}" \
		"${TARGET_ROM_ZIP}" \
		"${MD5SUM}" \
		"$(basename "${TARGET_FILES_ZIP}")" \
		"${ROM_OUTPUT_DIR}/system/build.prop" \
		"${CM_BUILDTYPE}" \
		"${SOURCE_TIMESTAMP}" \
		"${CHANGELOG_FILE}"
fi

if [ -d "${TARGET_FILES_DIRECTORY}" ]
then
	# remove old target files
	for FILE in $(find "${TARGET_FILES_DIRECTORY}" -type f -mtime +${DELETE_ROMS_FIND_MTIME} -print)
	do
		echo "Removing '${FILE}'..."
		rm $FILE
	done

	# Incrementals were automatically disabled while disabling the original rom so we can safely delete these now.
	for FILE in $(find "${INCREMENTAL_UPDATES_DIRECTORY}" -type f -mtime +${DELETE_ROMS_FIND_MTIME} -print)
	do
		echo "Removing '${FILE}'..."
		rm $FILE
	done

	# Building incrementals is only possible if the database script exists.
	if rom_db_is_available
	then
		if [[ "${SKIP_BUILDING_INCREMENTALS}" == "true" ]]
		then
			echo "Skipping building incrementals"
		else
			TARGET_FILES_FILENAME="$(basename "${TARGET_FILES_ZIP}")"
			INCREMENTAL_ID=$(cat $ROM_OUTPUT_DIR/system/build.prop | grep "ro.build.version.incremental" | cut -d'=' -f2)
			BUILD_TIMESTAMP=$(cat $ROM_OUTPUT_DIR/system/build.prop | grep "ro.build.date.utc" | cut -d'=' -f2)

			SOURCE_TARGET_FILES=$(rom_db_get_target_files_zip_names "${DEVICE_ID}" "${ROM_SUBDIRECTORY}" "${DELETE_ROMS_OLDER_THAN}")

			for OLD_TARGET_FILES_ZIP in $SOURCE_TARGET_FILES
			do
				# Skip source == target
				if [ "${TARGET_FILES_FILENAME}" == "${OLD_TARGET_FILES_ZIP}" ]
				then
					continue
				fi

				CMUPDATERINCREMENTAL_HELPER_MAKEFILE="external/helper_cmupdaterincremental/build.mk"

				OLD_TARGET_FILES_ZIP_PATH="${TARGET_FILES_DIRECTORY}/${OLD_TARGET_FILES_ZIP}"
				OLD_ID_WITH_ENDING="${OLD_TARGET_FILES_ZIP##*-}"
				OLD_INCREMENTAL_ID="${OLD_ID_WITH_ENDING%%.*}"

				if [ ! -e "${OLD_TARGET_FILES_ZIP_PATH}" ]
				then
					echo "${OLD_TARGET_FILES_ZIP_PATH} does not exist - skipping building incremental update for it."
					continue
				fi

				echo "Building incremental update from ${OLD_TARGET_FILES_ZIP} (incrementalid: ${OLD_ID}) to ${TARGET_FILES_FILENAME} (incrementalid: ${INCREMENTAL_ID})."

				INCREMENTAL_FILENAME="incremental-${OLD_INCREMENTAL_ID}-${INCREMENTAL_ID}.zip"
				INCREMENTAL_FILE_PATH="${INCREMENTAL_UPDATES_DIRECTORY}/${INCREMENTAL_FILENAME}"

				# Target cmupdaterincremental is not upstream thus it can only be used for custom builds.
				# For all other builds we simply use the command provided in OTA_FROM_TARGET_FILES_SCRIPT.
				if [ -n "${OTA_FROM_TARGET_FILES_SCRIPT}" ]
				then
					time $SCHEDULING $OTA_FROM_TARGET_FILES_SCRIPT \
						--worker_threads "${PARALLEL_JOBS}" \
						--incremental_from "${OLD_TARGET_FILES_ZIP_PATH}" \
						"${TARGET_FILES_ZIP}" \
						"${INCREMENTAL_FILE_PATH}"
				elif [ -e "${CMUPDATERINCREMENTAL_HELPER_MAKEFILE}" ]
				then
					time $SCHEDULING make \
						OTA_FROM_TARGET_SCRIPT_EXTRA_OPTS="--worker_threads ${PARALLEL_JOBS}" \
						INCREMENTAL_SOURCE_BUILD_ID="${OLD_INCREMENTAL_ID}" \
						INCREMENTAL_SOURCE_TARGETFILES_ZIP="${OLD_TARGET_FILES_ZIP_PATH}" \
						WITHOUT_CHECK_API=true \
						ONE_SHOT_MAKEFILE="${CMUPDATERINCREMENTAL_HELPER_MAKEFILE}" \
						cmupdaterincremental
				else
					echo "ERROR: No strategy for building incremental updates found!"
				fi

				mv "${ROM_OUTPUT_DIR}/${INCREMENTAL_FILENAME}" "${INCREMENTAL_FILE_PATH}"

				rom_db_add_incremental \
					"${ROM_SUBDIRECTORY}" \
					"${INCREMENTAL_FILE_PATH}" \
					"$(md5sum "${INCREMENTAL_FILE_PATH}" | cut -d' ' -f1)" \
					"${OLD_TARGET_FILES_ZIP}" \
					"${TARGET_FILES_FILENAME}" \
					"${BUILD_TIMESTAMP}"
			done
		fi
	fi
else
	echo "Incremental updates are not handled since their directory (${TARGET_FILES_DIRECTORY}) does not exist."
fi

mv "${TARGET_ROM_ZIP}" "${PUBLIC_ROM_DIRECTORY}"
mv "${TARGET_ROM_MD5SUM}" "${PUBLIC_ROM_DIRECTORY}"
mv "${TARGET_FILES_ZIP}" "${TARGET_FILES_DIRECTORY}"

find "${PUBLIC_ROM_DIRECTORY}" -type f -exec chmod 644 {} \;
