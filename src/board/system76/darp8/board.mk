# SPDX-License-Identifier: GPL-3.0-only

board-y += board.c
board-y += gpio.c

EC=ite
CONFIG_EC_ITE_IT5570E=y

# Enable eSPI
CONFIG_BUS_ESPI=y

# Include keyboard
KEYBOARD=15in_102

# Set keyboard LED mechanism
KBLED=rgb_pwm

# Set battery I2C bus
CFLAGS+=-DI2C_SMBUS=I2C_4

# Set touchpad PS2 bus
CFLAGS+=-DPS2_TOUCHPAD=PS2_3

# Set smart charger parameters
CHARGER=oz26786
CFLAGS+=\
	-DCHARGER_ADAPTER_RSENSE=10 \
	-DCHARGER_BATTERY_RSENSE=10 \
	-DCHARGER_CHARGE_CURRENT=3072 \
	-DCHARGER_CHARGE_VOLTAGE=8800 \
	-DCHARGER_INPUT_CURRENT=4740

# Set CPU power limits in watts
CFLAGS+=\
	-DPOWER_LIMIT_AC=65 \
	-DPOWER_LIMIT_DC=45

# Custom fan curve
CFLAGS+=-DBOARD_FAN_POINTS="\
	FAN_POINT(0, 20), \
	FAN_POINT(65, 20), \
	FAN_POINT(70, 30), \
	FAN_POINT(75, 40), \
	FAN_POINT(80, 50), \
	FAN_POINT(85, 62), \
	FAN_POINT(90, 75), \
	FAN_POINT(95, 90), \
	FAN_POINT(97, 100) \
"

# Add system76 common code
include src/board/system76/common/common.mk
