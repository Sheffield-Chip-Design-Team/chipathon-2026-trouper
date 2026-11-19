"""List PDN-via macro cells and their geometry bounds in a GDS."""
import pya
ly = pya.Layout()
ly.read(globals()["gds"])
for cell in ly.each_cell():
    n = cell.name.lower()
    if "via2_3" in n or "via3_4" in n or "via4_5" in n:
        print(cell.name, cell.bbox())
