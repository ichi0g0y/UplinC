.PHONY: build run install uninstall package clean check

build:
	./scripts/build_app.sh

run: build
	open "$(CURDIR)/build/UplinC.app"

install: build
	./scripts/install_launch_agent.sh

uninstall:
	./scripts/uninstall_launch_agent.sh

package:
	./scripts/package_release.sh

clean:
	rm -rf build dist

check:
	clang -fobjc-arc -Wall -Wextra -framework AppKit -framework UserNotifications Sources/UplinC/*.m -o /tmp/UplinC-check
	plutil -lint Resources/Info.plist
	zsh -n scripts/build_app.sh
	zsh -n scripts/install_launch_agent.sh
	zsh -n scripts/uninstall_launch_agent.sh
	zsh -n scripts/package_release.sh
