TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = YTDownload
YTDownload_FILES = Tweak.m
YTDownload_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
YTDownload_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia
YTDownload_INSTALL_PATH = @rpath

include $(THEOS_MAKE_PATH)/library.mk
