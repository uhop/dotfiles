#!/usr/bin/env bash

BLACK=$(tput setaf 0)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
MAGENTA=$(tput setaf 5)
CYAN=$(tput setaf 6)
WHITE=$(tput setaf 7)
RESET_COLOR=$(tput setaf 9)

FG_BLACK=BLACK
FG_RED=RED
FG_GREEN=GREEN
FG_YELLOW=YELLOW
FG_BLUE=BLUE
FG_MAGENTA=MAGENTA
FG_CYAN=CYAN
FG_WHITE=WHITE
FG_RESET=RESET_COLOR

BG_BLACK=$(tput setab 0)
BG_RED=$(tput setab 1)
BG_GREEN=$(tput setab 2)
BG_YELLOW=$(tput setab 3)
BG_BLUE=$(tput setab 4)
BG_MAGENTA=$(tput setab 5)
BG_CYAN=$(tput setab 6)
BG_WHITE=$(tput setab 7)
BG_RESET=$(tput setab 9)

color_fg () { return "$(tput setaf "$1")"; }
color_bg () { return "$(tput setab "$1")"; }

BOLD=$(tput bold)
DIM=$(tput dim)
UNDERLINE_ON=$(tput smul)
UNDERLINE_OFF=$(tput rmul)
REVERSE=$(tput rev)
BLINK=$(tput blink)
INVISIBLE=$(tput invis)
STANDOUT_ON=$(tput smso)
STANDOUT_OFF=$(tput rmso)
ITALIC_ON=$(tput sitm)
ITALIC_OFF=$(tput ritm)
RESET=$(tput sgr0)

TEXT_BOLD=BOLD
TEXT_DIM=DIM
TEXT_UNDERLINE_ON=UNDERLINE_ON
TEXT_UNDERLINE_OFF=UNDERLINE_OFF
TEXT_REVERSE=REVERSE
TEXT_BLINK=BLINK
TEXT_INVISIBLE=INVISIBLE
TEXT_STANDOUT_ON=STANDOUT_ON
TEXT_STANDOUT_OFF=STANDOUT_OFF
TEXT_ITALIC_ON=ITALIC_ON
TEXT_ITALIC_OFF=ITALIC_OFF
TEXT_RESET=RESET

CURSOR_SAVE=$(tput sc)
CURSOR_RESTORE=$(tput rc)
CURSOR_HOME=$(tput home)
CURSOR_DOWN1=$(tput cud1)
CURSOR_UP1=$(tput cuu1)
CURSOR_LEFT1=$(tput cub1)
CURSOR_RIGHT1=$(tput cuf1)
CURSOR_INVISIBLE=$(tput civis)
CURSOR_NORMAL=$(tput cnorm)
CURSOR_CLEAR_BEGIN=$(tput el1)
CURSOR_CLEAR_END=$(tput el)
CURSOR_LAST=$(tput ll)

cursor_pos    () { return "$(tput cup "$1" "$2")"; }
cursor_left   () { return "$(tput cub "$1")"; }
cursor_right  () { return "$(tput cuf "$1")"; }
cursor_clear  () { return "$(tput ech "$1")"; }
cursor_insert () { return "$(tput ich "$1")"; }
cursor_insert_lines () { return "$(tput il "$1")"; }

SCREEN_SAVE=$(tput smcup)
SCREEN_RESTORE=$(tput rmcup)
SCREEN_CLEAR=$(tput clear)
SCREEN_CLEAR_END=$(tput ed)

screen_lines  () { return "$(tput lines)"; }
screen_cols   () { return "$(tput cols)"; }
screen_colors () { return "$(tput colors)"; }

terminal_name () { return "$(tput longname)"; }
