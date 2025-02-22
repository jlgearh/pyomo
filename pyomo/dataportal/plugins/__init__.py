#  ___________________________________________________________________________
#
#  Pyomo: Python Optimization Modeling Objects
#  Copyright (c) 2008-2022
#  National Technology and Engineering Solutions of Sandia, LLC
#  Under the terms of Contract DE-NA0003525 with National Technology and
#  Engineering Solutions of Sandia, LLC, the U.S. Government retains certain
#  rights in this software.
#  This software is distributed under the 3-clause BSD License.
#  ___________________________________________________________________________


def load():
    import pyomo.dataportal.plugins.csv_table
    import pyomo.dataportal.plugins.datacommands
    import pyomo.dataportal.plugins.db_table
    import pyomo.dataportal.plugins.json_dict
    import pyomo.dataportal.plugins.text
    import pyomo.dataportal.plugins.xml_table
    import pyomo.dataportal.plugins.sheet
