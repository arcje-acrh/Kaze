cmake_minimum_required(VERSION 3.21)
project(kaze VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Gui Quick Network DBus)
qt_standard_project_setup(REQUIRES 6.5)
qt_policy(SET QTP0004 NEW)

# the QML module (UI + Fs / Folder) is a library, so the UI test can load the same thing the app does
qt_add_library(kazeui STATIC)
set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
qt_add_qml_module(kazeui
    URI Kaze
    OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/Kaze
    SOURCES src/fs.h src/folder.h
    QML_FILES
        qml/Main.qml qml/Theme.qml qml/Items.qml qml/Columns.qml qml/Sidebar.qml
        qml/Preview.qml qml/QuickLook.qml qml/Menu.qml qml/Prompt.qml qml/Key.qml qml/FileIcon.qml qml/Grip.qml qml/Pane.qml qml/Details.qml qml/LookSheet.qml qml/Jobs.qml qml/LedBar.qml qml/NetSheet.qml qml/Btn.qml qml/Choice.qml qml/Switch.qml qml/Conflicts.qml qml/Usage.qml qml/Props.qml qml/VideoPlay.qml
)
target_include_directories(kazeui PUBLIC src)
target_link_libraries(kazeui PUBLIC Qt6::Gui Qt6::Quick Qt6::Network)

qt_add_executable(kaze src/main.cpp src/dbus.h)
target_link_libraries(kaze PRIVATE kazeui kazeuiplugin Qt6::DBus)

install(TARGETS kaze RUNTIME DESTINATION bin)
install(FILES kaze.desktop DESTINATION share/applications)
install(PROGRAMS tools/kaze-share DESTINATION lib/kaze)   # root helper for network locations (run through pkexec)
install(FILES tools/org.freedesktop.FileManager1.service DESTINATION share/kaze)   # "Show in folder": copy to ~/.local/share/dbus-1/services/

# self-check of the file operations: ctest --test-dir build
# tests (kept out of the public repo): built only when tests/ is there
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_fs.cpp)
    find_package(Qt6 REQUIRED COMPONENTS Test)
    qt_add_executable(kaze_test tests/test_fs.cpp src/fs.h)
    target_include_directories(kaze_test PRIVATE src)
    target_link_libraries(kaze_test PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network Qt6::Test)
    enable_testing()
    add_test(NAME fs COMMAND kaze_test)
    # clicks through the real UI (offscreen): sidebar, path bar, rows, column view, split view
    qt_add_executable(kaze_uitest tests/test_ui.cpp)
    target_link_libraries(kaze_uitest PRIVATE kazeui kazeuiplugin Qt6::Test)
    target_compile_definitions(kaze_uitest PRIVATE KAZE_SOURCE="${CMAKE_CURRENT_SOURCE_DIR}")
    add_test(NAME ui COMMAND kaze_uitest)
    set_tests_properties(ui PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software")
endif()
