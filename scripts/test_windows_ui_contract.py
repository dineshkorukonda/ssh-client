import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
X = "{http://schemas.microsoft.com/winfx/2006/xaml}"
P = "{http://schemas.microsoft.com/winfx/2006/xaml/presentation}"


class WindowsUIContract(unittest.TestCase):
    def test_application_resource_keys_are_unique(self):
        resources = ET.parse(ROOT / "windows/native/App.xaml").getroot().find(P + "Application.Resources")
        keys = [item.get(X + "Key") or item.get("TargetType") for item in resources]
        keys = [key for key in keys if key]
        self.assertEqual(len(keys), len(set(keys)), "Duplicate WPF resources can compile but crash at startup")

    def test_host_editor_actions_are_outside_the_scroll_viewer(self):
        root = ET.parse(ROOT / "windows/native/MainWindow.xaml").getroot()
        editor = next(item for item in root.iter() if item.get(X + "Name") == "HostEditorGrid")
        for scroll in editor.iter(P + "ScrollViewer"):
            self.assertFalse(any(item.get("Click") in {"EditorSave_Click", "EditorSaveAndConnect_Click"} for item in scroll.iter()))
        self.assertTrue(any(item.get("Click") == "EditorSave_Click" for item in editor.iter()))

    def test_native_security_surface_has_no_mock_credentials_or_master_vault(self):
        text = (ROOT / "windows/native/MainWindow.xaml").read_text(encoding="utf-8")
        self.assertNotIn("password123", text)
        self.assertNotIn("Unlock Master Vault", text)
        self.assertNotIn('Text="v2.4"', text)
        self.assertIn('Content="Lock Windows"', text)


if __name__ == "__main__":
    unittest.main()
