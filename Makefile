TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GroupSearch
GroupSearch_FILES = Tweak.x
GroupSearch_FRAMEWORKS = UIKit Foundation
GroupSearch_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 MobileSMS"
