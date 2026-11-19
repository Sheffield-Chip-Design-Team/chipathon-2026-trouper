"""Negative control: paint a deliberate VDD<->VSS short into the bridged GDS.

A tall thin Metal1 box over the core crosses several std-cell-row follow-pin
rails, which alternate VDD / VSS -> guaranteed rail short. If the extract+LVS
harness is sound it must flip 'match uniquely' to a mismatch and name VDD/VSS.

    klayout -b -r inject_short.py -rd src=<gds> -rd out=<gds> -rd x=<um> -rd y0=<um> -rd y1=<um>
"""
import pya

src = globals()["src"]
out = globals()["out"]
xu = float(globals().get("x", 800.0))
y0 = float(globals().get("y0", 500.0))
y1 = float(globals().get("y1", 545.0))
LAYER = (int(globals().get("layer", 34)), 0)   # Metal1 drawn

ly = pya.Layout()
ly.read(src)
dbu = ly.dbu
top = ly.cell("trouper_top") or ly.top_cell()
li = ly.layer(LAYER[0], LAYER[1])
box = pya.Box(int(xu / dbu), int(y0 / dbu),
              int((xu + 0.5) / dbu), int(y1 / dbu))
top.shapes(li).insert(box)
ly.write(out)
print("injected M%d short box um x[%.2f,%.2f] y[%.2f,%.2f] into %s"
      % (LAYER[0], xu, xu + 0.5, y0, y1, top.name))
print("wrote", out)
