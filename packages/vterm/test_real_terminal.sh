#!/bin/bash
# Test real terminal cursor behavior

# Set terminal to 5 columns for testing
stty cols 5

# Clear screen and go to top-left
printf "\033[2J\033[H"

# Write exactly 5 characters
printf "Hello"

# Query cursor position (ESC[6n)
printf "\033[6n"

# Read the response
read -r response

echo
echo "Response: $response"

# Reset terminal
stty cols 80