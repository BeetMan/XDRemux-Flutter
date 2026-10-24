#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* drop_channel;
  gboolean cli_files_delivered;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Desktop drop target: GTK hands us a text/uri-list of dropped files, which we
// forward to Dart on the same channel the Windows and macOS runners use.
static const GtkTargetEntry kDropTargets[] = {
    {(gchar*)"text/uri-list", 0, 0},
};

static void on_drag_data_received(GtkWidget* widget, GdkDragContext* context,
                                  gint x, gint y,
                                  GtkSelectionData* selection_data, guint info,
                                  guint time, MyApplication* self) {
  g_autoptr(FlValue) paths = fl_value_new_list();
  gchar** uris = gtk_selection_data_get_uris(selection_data);
  if (uris != nullptr) {
    for (gchar** uri = uris; *uri != nullptr; uri++) {
      g_autofree gchar* path = g_filename_from_uri(*uri, nullptr, nullptr);
      if (path != nullptr) {
        fl_value_append_take(paths, fl_value_new_string(path));
      }
    }
    g_strfreev(uris);
  }

  gboolean accepted = FALSE;
  if (fl_value_get_length(paths) > 0 && self->drop_channel != nullptr) {
    g_debug("xdremux: forwarding %zu dropped path(s) to Dart",
            fl_value_get_length(paths));
    fl_method_channel_invoke_method(self->drop_channel, "onFilesDropped", paths,
                                    nullptr, nullptr, nullptr);
    accepted = TRUE;
  }
  gtk_drag_finish(context, accepted, FALSE, time);
}

static void setup_drop_target(GtkWidget* widget, MyApplication* self) {
  gtk_drag_dest_set(widget, GTK_DEST_DEFAULT_ALL, kDropTargets,
                    G_N_ELEMENTS(kDropTargets), GDK_ACTION_COPY);
  g_signal_connect(widget, "drag-data-received",
                   G_CALLBACK(on_drag_data_received), self);
}

// Window icon shipped at <executable dir>/data/app_icon.png by CMake. GTK on
// Wayland has no toplevel icon support, so this is best-effort (X11 uses it).
static void set_window_icon(GtkWindow* window) {
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path == nullptr) return;
  g_autofree gchar* exe_dir = g_path_get_dirname(exe_path);
  g_autofree gchar* icon_path =
      g_build_filename(exe_dir, "data", "app_icon.png", nullptr);
  if (g_file_test(icon_path, G_FILE_TEST_IS_REGULAR)) {
    gtk_window_set_icon_from_file(window, icon_path, nullptr);
  }
}

// Files given on the command line (`xdremux photo.heic ...`) are forwarded to
// the same Dart intake the drop channel uses, once the Dart handler exists.
static void append_cli_file_arg(FlValue* paths, const gchar* arg) {
  if (arg == nullptr || arg[0] == '\0' || arg[0] == '-') return;
  g_autofree gchar* path = g_canonicalize_filename(arg, nullptr);
  if (g_file_test(path, G_FILE_TEST_IS_REGULAR)) {
    fl_value_append_take(paths, fl_value_new_string(path));
  }
}

static void deliver_cli_files(MyApplication* self) {
  if (self->cli_files_delivered || self->drop_channel == nullptr) return;
  self->cli_files_delivered = TRUE;
  g_autoptr(FlValue) paths = fl_value_new_list();
  if (self->dart_entrypoint_arguments != nullptr) {
    for (gchar** arg = self->dart_entrypoint_arguments; *arg != nullptr;
         arg++) {
      append_cli_file_arg(paths, *arg);
    }
  }
  if (fl_value_get_length(paths) > 0) {
    g_debug("xdremux: forwarding %zu CLI path(s) to Dart",
            fl_value_get_length(paths));
    fl_method_channel_invoke_method(self->drop_channel, "onFilesDropped", paths,
                                    nullptr, nullptr, nullptr);
  }
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  // Dart's HomePage registers the drop handler in initState, which has run by
  // the time the first frame is rendered, so CLI files can be delivered now.
  deliver_cli_files(self);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "XDRemux");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "XDRemux");
  }

  gtk_window_set_default_size(window, 1280, 820);
  set_window_icon(window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // Native <-> Dart channel for desktop file drops and command-line file open.
  // The Dart side listens for "onFilesDropped" with a List<String> of absolute
  // paths (lib/main.dart: _initDropChannel).
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->drop_channel = fl_method_channel_new(
      messenger, "xdremux/drop", FL_METHOD_CODEC(codec));

  // Accept drops on the toplevel and on the Flutter view (the view forwards
  // child-window drops up the GTK hierarchy either way).
  setup_drop_target(GTK_WIDGET(window), self);
  setup_drop_target(GTK_WIDGET(view), self);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->drop_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
