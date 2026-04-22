function x-add-todo
    set -l input (gum write --placeholder "Add a new todo...")
    if test -n "$input"
        echo $input >> todo.txt
        gum spin --spinner line --title "Added todo!" -- sleep 0.5
    else
        gum style --foreground 196 "No input provided, nothing added."
    end
end
